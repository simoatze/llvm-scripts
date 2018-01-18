#!/bin/bash
set -e

if [ "$(uname)" == "Linux" ]; then
    ESCAPE="\e"
else
    ESCAPE="\x1B"
fi

ARCH=$(uname -m)
if [[ $HOSTNAME == node* ]]; then
  ARCH=${ARCH}"_k26"
fi

RED=$ESCAPE'[0;31m'
GREEN=$ESCAPE'[0;32m'
NC=$ESCAPE'[0m'
echoc() { echo -e "${RED}$@${NC}"; }
echook() { echo -e "${GREEN}$@${NC}"; }

git_clone_or_pull() # $1 = url, $2 = target directory
{
if [ "$1" = "-b" ]
then
    local BRANCH=$2
    shift;shift;
fi

if [ ! -d $2 ]
then
    git clone $1 $2
    if [ -n "$BRANCH" ]
    then
        cd $2
        git checkout $BRANCH
    fi
    if [ -n "$3" ]
    then
        cd $2
        git checkout $3
    fi
else
    cd $2
    if [ -n "$BRANCH" ]
    then
        git checkout $BRANCH
    fi
    if [ -n "$3" ]
    then
        git checkout $3
    fi
    if [ "$UPDATE" == "false" ]
    then
        return
    fi
    git pull $1 $BRANCH
fi
}

check_version() # $1 = reference version, $2 tool , return false, iff $1 > version($2)
{
version1=$(echo $1 | sed 's/[^[:digit:]^.]//g' | tr '.' ' ')
toolversion=$($2 --version 2>&1 | head -n1 | sed -e 's/([^)]*)//g' -e 's/\[[^]]*\]//g' -e 's/  */ /g')
version2=$(echo $toolversion | sed 's/[^[:digit:]^.]//g' | tr '.' ' ')
#version2=$(echo $2 | sed 's/[^[:digit:]^.]//g' | tr '.' ' ')
read -r -a v1 <<< $version1
read -r -a v2 <<< $version2
for i in $(seq 0 $[${#v1[@]}-1])
do
    if [ 0${v1[$i]} -gt 0${v2[$i]} ]
    then
        return 1
    fi
    if [ 0${v1[$i]} -lt 0${v2[$i]} ]
    then
        return 0
    fi
done
return 0
}

BASE=
LLVM_INSTALL=/usr
RELEASE="dev"
HTTP=false
UPDATE=false
GIT_URL=llvm-mirror
YORKTOWN=false
BOOTSTRAP=true
YKT_FLAG=""
BUILD_TYPE=Release
GCC_TOOLCHAIN_PATH=
BUILD_CMD=ninja
BUILD_SYSTEM="Ninja"
if ! command_loc="$(type -p "$BUILD_CMD")" || [ -z "$command_loc" ]; then
    BUILD_CMD=make
    BUILD_SYSTEM="Unix Makefiles"
fi

if [ $# -eq 0 ]
then
    echo "Usage"
    echo
    echo "  ./install.sh [options] <path-to-installation-folder>"
    echo
    echo "Run './install.sh --help' for more information."
    echo
    exit
fi

# CC and CXX
for i in "$@"
do
    case $i in
        --prefix=*)
            LLVM_INSTALL="${i#*=}"
            shift
            ;;
        --build-system=*)
            BUILD_SYSTEM="${i#*=}"
            shift
            ;;
        --release=*)
            RELEASE="${i#*=}"
            shift
            ;;
        --http)
            HTTP=true
            shift
            ;;
        --update)
            UPDATE=true
            shift
            ;;
        --yorktown)
            GIT_URL=clang-ykt
            YORKTOWN=true
            shift
            ;;
        --no-bootstrap)
            BOOTSTRAP=false
            shift
            ;;
        --build-type=*)
            BUILD_TYPE="${i#*=}"
            shift
            ;;
        --gcc-toolchain-path=*)
            GCC_TOOLCHAIN_PATH="-D GCC_INSTALL_PREFIX=${i#*=}"
            shift
            ;;
        --help)
            echo "Usage"
            echo
            echo "  ./install.sh [options]"
            echo
            echo "Options"
            echo "  --prefix=<value>             = Specify an installation path."
            echo "  --build-system=<value>       = Specify a build system generator. Please run"
            echo "                                 'man cmake-generators' for a list of generators"
            echo "                                 available for this platform."
            echo "  --release=<value>            = Specify the release version of Clang/LLVM that"
            echo "                                 will be installed (>= 39)."
            echo "  --http                       = Enables GitHub web url in case SSH key and"
            echo "                                 passphrase are not set in the GitHub account."
            echo "  --update                     = Update previous building."
            echo "  --build-type=<value>         = Specify the type of build. Accepted values"
            echo "                                 are Release (default), Debug or RelWithDebInfo."
            echo "  --gcc-toolchain-path=<value> = Specify the GCC toolchain path."
            echo
            shift
            exit
            ;;
        *)
            BASE=${i#*=}
            shift
            ;;
    esac
done

if [ -z "$BASE" ];
then
    echo
    echo "Error: Specify a directory to download and build the software."
    echo
    exit
fi

if [[ ( "${BUILD_TYPE}" != "Release" ) && ( "${BUILD_TYPE}" != "Debug" ) && ( "${BUILD_TYPE}" != "RelWithDebInfo" ) ]]; then
    echo
    echo "Error: Accepted values for the build type are Release, Debug, or RelWithDebInfo."
    echo
    exit
fi

# Check requirements
myerrors=0
toolversion=0
if mygit=$(which git 2>/dev/null)
then
    echook Found git at $mygit [OK]
else
    echoc Cannot find git. Necessary for building Clang/LLVM. [ERROR]
    myerrors=1
fi

if mycmake=$(which cmake 2>/dev/null)
then
#    mycmakeversion=$($mycmake --version 2>&1 | head -n1 | sed -e 's/(.*)//g' -e 's/\[.*\]//g' -e 's/  */ /g')
    if check_version 3.4.3 $mycmake
    then
        echook Found cmake at $mycmake version $toolversion [OK]
    else
        echoc Found cmake at $mycmake version $toolversion , but version 3.4.3 or newer required [ERROR]
        myerrors=1
    fi
else
    echoc Cannot find cmake. Necessary for building Clang/LLVM. [ERROR]
    myerrors=1
fi

if mygcc=$(which gcc 2>/dev/null)
then
#    mygccversion=$($mygcc --version 2>&1 | head -n1 | sed -e 's/(.*)//g' -e 's/\[.*\]//g' -e 's/  */ /g')
    if check_version 4.7 $mygcc
    then
        echook Found gcc at $mygcc version $toolversion [OK]
    else
        echoc Found gcc at $mygcc version $toolversion , but version 4.7 or newer required [ERROR]
        myerrors=1
    fi
else
    echoc Cannot find gcc. Necessary for building Clang/LLVM. [ERROR]
    myerrors=1
fi

if mypython=$(which python 2>/dev/null)
then
#    mypythonversion=$($mypython --version 2>&1 | head -n1 | sed -e 's/(.*)//g' -e 's/\[.*\]//g' -e 's/  */ /g')
    if check_version 2.7 $mypython
    then
        echook Found python at $mypython version $toolversion [OK]
    else
        echoc Found python at $mypython version $toolversion, but version 2.7 or newer required [ERROR]
        myerrors=1
    fi
else
    echoc Cannot find python. Necessary for building Clang/LLVM. [ERROR]
    myerrors=1
fi

if [ $myerrors -gt 0 ]
then
    echoc Stop building Clang/LLVM for missing requirements.
    exit 1
fi

LLVM_INSTALL=${LLVM_INSTALL}"_"${ARCH}"_"${BUILD_TYPE,,}
echo
echook "LLVM will be installed at [${LLVM_INSTALL}]"

# Saving installation patch
# echo ${LLVM_INSTALL} > .install_path

# Get the number of cores to speed up make process
if [ "$(uname)" == "Darwin" ]; then
    PROCS=$(sysctl -a | grep machdep.cpu | grep core_count | awk -F " " '{ print $2 }')
else
    if ! type "nproc" > /dev/null; then
        PROCS=$(nproc --all)
    else
        PROCS=$(cat /proc/cpuinfo | awk '/^processor/{print $3}' | tail -1)
        PROCS=`expr $PROCS + 1`
    fi
fi
#fair share:
# PROCS=$[$PROCS/2]

echook "Installing LLVM/Clang..."

cd ..
WORKING_DIR=`pwd`
BASE=${BASE}"_"${ARCH}"_"${BUILD_TYPE,,}
if [[ "$BASE" = /* ]]; then
    BASE=${BASE}
else
    BASE=$WORKING_DIR/${BASE}
fi
mkdir -p ${BASE}
cd ${BASE}

# Software Repositories
LLVM_REPO=""
CLANG_REPO=""
LLVMRT_REPO=""
LLVM_COMMIT=""
LLVMRT_COMMIT=""
CLANG_COMMIT=""
if [ "$HTTP" == "true" ]; then
    LLVM_REPO="https://github.com/${GIT_URL}/llvm.git"
    CLANG_REPO="https://github.com/${GIT_URL}/clang.git"
    LLVMRT_REPO="https://github.com/${GIT_URL}/compiler-rt.git"
    LIBCXX_REPO="https://github.com/${GIT_URL}/libcxx.git"
    LIBCXXABI_REPO="https://github.com/${GIT_URL}/libcxxabi.git"
    LIBUNWIND_REPO="https://github.com/${GIT_URL}/libunwind.git"
    OPENMPRT_REPO="https://github.com/${GIT_URL}/openmp.git"
else
    LLVM_REPO="git@github.com:${GIT_URL}/llvm.git"
    CLANG_REPO="git@github.com:${GIT_URL}/clang.git"
    LLVMRT_REPO="git@github.com:${GIT_URL}/compiler-rt.git"
    LIBCXX_REPO="git@github.com:${GIT_URL}/libcxx.git"
    LIBCXXABI_REPO="git@github.com:${GIT_URL}/libcxxabi.git"
    LIBUNWIND_REPO="git@github.com:${GIT_URL}/libunwind.git"
    OPENMPRT_REPO="git@github.com:${GIT_URL}/openmp.git"
fi

if [ "$RELEASE" == "dev" ]; then
    LLVM_RELEASE=
    CLANG_RELEASE=
    LLVMRT_RELEASE=
    LIBCXX_RELEASE=
    LIBCXXABI_RELEASE=
    LIBUNWIND_RELEASE=
    OPENMPRT_RELEASE=
else
    LLVM_RELEASE="release_"$RELEASE
    CLANG_RELEASE="release_"$RELEASE
    LLVMRT_RELEASE="release_"$RELEASE
    LIBCXX_RELEASE="release_"$RELEASE
    LIBCXXABI_RELEASE="release_"$RELEASE
    LIBUNWIND_RELEASE="release_"$RELEASE
    OPENMPRT_RELEASE="release_"$RELEASE
fi

# LLVM installation directory
LLVM_SRC=${BASE}/llvm_src
CLANG_SRC=${BASE}/llvm_src/tools/clang
LLVMRT_SRC=${BASE}/llvm_src/projects/compiler-rt
OPENMPRT_SRC=${BASE}/llvm_src/projects/openmp
LIBCXX_SRC=${BASE}/llvm_src/projects/libcxx
LIBCXXABI_SRC=${BASE}/llvm_src/projects/libcxxabi
LIBUNWIND_SRC=${BASE}/llvm_src/projects/libunwind
LLVM_BOOTSTRAP=${BASE}/llvm_bootstrap
LLVM_BUILD=${BASE}/llvm_build

# Obtaining the sources

# LLVM Sources
echo
echook "Obtaining LLVM..."
git_clone_or_pull ${LLVM_REPO} ${LLVM_SRC} ${LLVM_RELEASE}

# Clang Sources
echo
echook "Obtaining LLVM/Clang..."
git_clone_or_pull ${CLANG_REPO} ${CLANG_SRC} ${CLANG_RELEASE}

if [ "$YORKTOWN" == "false" ]; then
    # Runtime Sources
    echo
    echook "Obtaining LLVM Runtime..."
    git_clone_or_pull ${LLVMRT_REPO} ${LLVMRT_SRC} ${LLVMRT_RELEASE}
fi

# OpenMP Runtime Sources
echo
echook "Obtaining LLVM OpenMP Runtime..."
git_clone_or_pull ${OPENMPRT_REPO} ${OPENMPRT_SRC} ${OPENMPRT_RELEASE}

if [ "$YORKTOWN" == "false" ]; then
    # libc++ Sources
    echo
    echook "Obtaining LLVM libc++..."
    git_clone_or_pull ${LIBCXX_REPO} ${LIBCXX_SRC} ${LIBCXX_RELEASE}

    # libc++abi Sources
    echo
    echook "Obtaining LLVM libc++abi..."
    git_clone_or_pull ${LIBCXXABI_REPO} ${LIBCXXABI_SRC} ${LIBCXXABI_RELEASE}

    # libunwind Sources
    echo
    echook "Obtaining LLVM libunwind..."
    git_clone_or_pull ${LIBUNWIND_REPO} ${LIBUNWIND_SRC} ${LIBUNWIND_RELEASE}
fi

# Compiling and installing LLVM
if [ "$BOOTSTRAP" == "true" ]; then
    echook "Bootstraping clang..."
    OLD_PATH=${PATH}
    OLD_LD_LIBRARY_PATH=${LD_LIBRARY_PATH}
    if [[ -f "${LLVM_BOOTSTRAP}/bin/clang" ]]; then
        echo "bootstrap already built!"
    else
        mkdir -p "${LLVM_BOOTSTRAP}" && cd "${LLVM_BOOTSTRAP}"
        CC=$(which gcc) CXX=$(which g++) cmake -G "${BUILD_SYSTEM}" \
          -DCMAKE_BUILD_TYPE=Release \
          -DLLVM_TARGETS_TO_BUILD=Native \
          -D LLVM_ENABLE_LIBCXX=ON \
          ${GCC_TOOLCHAIN_PATH} \
          "${LLVM_SRC}"
        cd "${LLVM_BOOTSTRAP}"
        ${BUILD_CMD} -j${PROCS}
    fi
    export LD_LIBRARY_PATH="${LLVM_BOOTSTRAP}/lib:${OLD_LD_LIBRARY_PATH}"
    export PATH="${LLVM_BOOTSTRAP}/bin:${OLD_PATH}"
    export CUDAPATH="/opt/cuda-8.0"
fi

echo
echook "Building LLVM/Clang..."
mkdir -p "${LLVM_BUILD}" && cd "${LLVM_BUILD}"
if [ "$YORKTOWN" == "false" ]; then
    cmake -G "${BUILD_SYSTEM}" \
          -D CMAKE_C_COMPILER=clang \
          -D CMAKE_CXX_COMPILER=clang++ \
          -D CMAKE_BUILD_TYPE=${BUILD_TYPE} \
          -D CMAKE_INSTALL_PREFIX:PATH=${LLVM_INSTALL} \
          -D LLVM_ENABLE_LIBCXX=ON \
          -D LIBCXXABI_USE_LLVM_UNWINDER=ON \
          -D CLANG_DEFAULT_OPENMP_RUNTIME:STRING=libomp \
          ${GCC_TOOLCHAIN_PATH} \
          ${LLVM_SRC}
else
    cmake -G "${BUILD_SYSTEM}" \
          -D CMAKE_BUILD_TYPE=${BUILD_TYPE} \
          -D CMAKE_C_COMPILER=clang \
          -D CMAKE_CXX_COMPILER=clang++ \
          -D CMAKE_INSTALL_PREFIX:PATH=${LLVM_INSTALL} \
          -D CLANG_DEFAULT_OPENMP_RUNTIME:STRING=libomp \
          -D LLVM_ENABLE_BACKTRACES=ON \
          -D LLVM_ENABLE_WERROR=OFF \
          -D BUILD_SHARED_LIBS=OFF \
          -D LLVM_ENABLE_RTTI=ON \
          -D OPENMP_ENABLE_LIBOMPTARGET=ON \
          -D CMAKE_C_FLAGS='-DOPENMP_NVPTX_COMPUTE_CAPABILITY=35' \
          -D CMAKE_CXX_FLAGS='-DOPENMP_NVPTX_COMPUTE_CAPABILITY=35' \
          -D LIBOMPTARGET_NVPTX_COMPUTE_CAPABILITY=35 \
          -D CLANG_OPENMP_NVPTX_DEFAULT_ARCH=sm_35 \
          -D LIBOMPTARGET_NVPTX_ENABLE_BCLIB=true \
          -D LIBOMPTARGET_DEP_LIBELF_INCLUDE_DIR=$HOME/system/${ARCH}/usr/include \
          -D LIBOMPTARGET_DEP_LIBFFI_INCLUDE_DIR=$HOME/system/${ARCH}/usr/lib/libffi-3.2.1/include \
          ${LLVM_SRC}
fi
${BUILD_CMD} -j${PROCS}
${BUILD_CMD} install

export PATH=${LLVM_INSTALL}/bin:${OLD_PATH}
export LD_LIBRARY_PATH=${LLVM_INSTALL}/lib:${OLD_LD_LIBRARY_PATH}

echo
echo "In order to use LLVM/Clang set the following path variables:"
echo
echook "export PATH=${LLVM_INSTALL}/bin:\${PATH}"
echook "export LD_LIBRARY_PATH=${LLVM_INSTALL}/lib:\${LD_LIBRARY_PATH}"
echo
echo "or add the previous line to your"
echo "shell start-up script such as \"~/.bashrc\"".
echo
echo
echook "LLVM installation completed."
echo
