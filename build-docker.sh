#!/usr/bin/env bash

: ${DOCKER_USER:=$(whoami)}
: ${ROCM_VERSIONS:="5.0"}
: ${PYTHON_VERSIONS:="8 9 10 11"}
: ${BUILD_CI:=""}
: ${PUSH:=0}
: ${PULL:=--pull}
: ${OUTPUT_VERBOSITY:=""}
: ${BUILD_OPENMPI:="1"}
: ${BUILD_AOMP_LATEST:="0"}
: ${BUILD_LLVM_LATEST:="0"}
: ${BUILD_GCC_LATEST:="0"}
: ${BUILD_OG_LATEST:="0"}
: ${BUILD_CLACC_LATEST:="0"}
: ${BUILD_PYTORCH:="0"}
: ${BUILD_CUPY:="0"}
: ${BUILD_ALL_LATEST:="0"}
: ${RETRY:=3}
: ${NO_CACHE:=""}
: ${OMNITRACE_BUILD_FROM_SOURCE:=0}
: ${ADMIN_USERNAME:="admin"}
: ${ADMIN_PASSWORD:=""}
: ${USE_CACHED_APPS:=0}
: ${AMDGPU_GFXMODEL:=""}

tolower()
{
    echo "$@" | awk -F '\\|~\\|' '{print tolower($1)}';
}

toupper()
{
    echo "$@" | awk -F '\\|~\\|' '{print toupper($1)}';
}

usage()
{
    print_option() { printf "    --%-20s %-24s     %s\n" "${1}" "${2}" "${3}"; }
    echo "Options:"
    print_option "help -h" "" "This message"
    print_option "no-pull" "" "Do not pull down most recent base container"

    echo ""
    print_default_option() { printf "    --%-20s %-24s     %s (default: %s)\n" "${1}" "${2}" "${3}" "$(tolower ${4})"; }
    print_default_option admin-username "[ADMIN_USERNAME]"
    print_default_option admin-password "[ADMIN_PASSWORD]"
    print_default_option build-aomp-latest -- flag to build the latest version of AOMP for offloading
    print_default_option build-llvm-latest -- flag to build the latest version of LLVM for offloading
    print_default_option build-gcc-latest -- flag to build the latest version of gcc with offloading
    print_default_option build-og-latest -- flag to build the latest version of gcc develop with offloading
    print_default_option build-clacc-latest -- flag to build the latest version of clacc with offloading
    print_default_option build-pytorch -- flag to build the latest version of pytorch
    print_default_option build-cupy -- flag to build the latest version of cupy
    print_default_option use_cached-apps -- flag to use pre-built gcc and aomp located in CacheFiles/${DISTRO}-${DISTRO_VERSION}-rocm-${ROCM_VERSION} directory
    print_default_option omnitrace-build-from-source -- flag to build omnitrace from source instead of using pre-built versions
    print_default_option output-verbosity -- flag to show more docker build output
    print_default_option distro "[ubuntu|opensuse|rhel]" "OS distribution" "${DISTRO}"
    print_default_option distro-versions "[VERSION] [VERSION...]" "Ubuntu, OpenSUSE, or RHEL release" "${DISTRO_VERSIONS}"
    print_default_option rocm-versions "[VERSION] [VERSION...]" "ROCm versions" "${ROCM_VERSIONS}"
    print_default_option python-versions "[VERSION] [VERSION...]" "Python 3 minor releases" "${PYTHON_VERSIONS}"
    print_default_option "docker_user" "[DOCKER_USERNAME]" "DockerHub username" "${DOCKER_USER}"
    print_default_option "retry" "[N]" "Number of attempts to build (to account for network errors)" "${RETRY}"
    print_default_option push "" "Push the image to Dockerhub" ""
    #print_default_option lto "[on|off]" "Enable LTO" "${LTO}"
}

send-error()
{
    usage
    echo -e "\nError: ${@}"
    exit 1
}

verbose-run()
{
    echo -e "\n### Executing \"${@}\"... ###\n"
    eval "${@}"
}

verbose-build()
{
    echo -e "\n### Executing \"${@}\" a maximum of ${RETRY} times... ###\n"
    for i in $(seq 1 1 ${RETRY})
    do
        set +e
        eval "${@}"
        local RETC=$?
        set -e
        if [ "${RETC}" -eq 0 ]; then
            break
        else
            echo -en "\n### Command failed with error code ${RETC}... "
            if [ "${i}" -ne "${RETRY}" ]; then
                echo -e "Retrying... ###\n"
                sleep 3
            else
                echo -e "Exiting... ###\n"
                exit ${RETC}
            fi
        fi
    done
}

reset-last()
{
    last() { send-error "Unsupported argument :: ${1}"; }
}

set -e

DISTRO=`lsb_release -i | cut -f2 | tr '[:upper:]' '[:lower:]'`
DISTRO_VERSIONS=`lsb_release -r | cut -f2`

AMDGPU_GFXMODEL=`rocminfo | grep gfx | sed -e 's/Name://' | head -1 |sed 's/ //g'`

n=0
while [[ $# -gt 0 ]]
do
    case "${1}" in
        "-h|--help")
            usage
            exit 0
            ;;
        "--distro")
            shift
            DISTRO=${1}
            last() { DISTRO="${DISTRO} ${1}"; }
            ;;
        "--distro-versions")
            shift
            DISTRO_VERSIONS=${1}
            last() { DISTRO_VERSIONS="${DISTRO_VERSIONS} ${1}"; }
            ;;
        "--rocm-versions")
            shift
            ROCM_VERSIONS=${1}
            last() { ROCM_VERSIONS="${ROCM_VERSIONS} ${1}"; }
            ;;
        "--python-versions")
            shift
            PYTHON_VERSIONS=${1}
            last() { PYTHON_VERSIONS="${PYTHON_VERSIONS} ${1}"; }
            ;;
        "--docker_user")
            shift
            DOCKER_USER=${1}
            reset-last
            ;;
        "--admin-username")
            shift
            ADMIN_USERNAME=${1}
            reset-last
            ;;
        "--admin-password")
            shift
            ADMIN_PASSWORD=${1}
            reset-last
            ;;
        "--amdgpu-gfxmodel")
            shift
            AMDGPU_GFXMODEL=${1}
            reset-last
            ;;
        "--omnitrace-build-from-source")
            OMNITRACE_BUILD_FROM_SOURCE=1
            reset-last
            ;;
        "--push")
            PUSH=1
            reset-last
            ;;
        "--output-verbosity")
            OUTPUT_VERBOSITY="--progress=plain"
            reset-last
            ;;
        "--no-cache")
            NO_CACHE=--no-cache
            reset-last
            ;;
        "--no-pull")
            PULL=""
            reset-last
            ;;
        "--retry")
            shift
            RETRY=${1}
            reset-last
            ;;
        "--build-openmpi")
            BUILD_OPENMPI="1"
            reset-last
            ;;
        "--build-aomp-latest")
            BUILD_AOMP_LATEST="1"
            reset-last
            ;;
        "--build-llvm-latest")
            BUILD_LLVM_LATEST="1"
            reset-last
            ;;
        "--build-gcc-latest")
            BUILD_GCC_LATEST="1"
            reset-last
            ;;
        "--build-og-latest")
            BUILD_OG_LATEST="1"
            reset-last
            ;;
        "--build-clacc-latest")
            BUILD_CLACC_LATEST="1"
            reset-last
            ;;
        "--build-pytorch")
            BUILD_PYTORCH="1"
            reset-last
            ;;
        "--build-cupy")
            BUILD_CUPY="1"
            reset-last
            ;;
        "--build-all-latest")
            BUILD_OPENMPI="1"
            BUILD_ALL_LATEST="1"
            BUILD_AOMP_LATEST="1"
            #BUILD_LLVM_LATEST="1"
            BUILD_GCC_LATEST="1"
            #BUILD_OG_LATEST="1"
            #BUILD_CLACC_LATEST="1"
            BUILD_PYTORCH="1"
            BUILD_CUPY="1"
            reset-last
            ;;
        "--use-cached-apps")
            USE_CACHED_APPS="1"
            reset-last
            ;;
        "--*")
            send-error "Unsupported argument at position $((${n} + 1)) :: ${1}"
            ;;
        *)
            last ${1}
            ;;
    esac
    n=$((${n} + 1))
    shift
done

if [ "x${ADMIN_PASSWORD}" == "x" ] ; then
	echo "A password for the admin user is required"
	echo " --admin-password <xxxx>"
	echo " --admin-username <admin>"
	exit;
fi

ROCM_DOCKER_OPTS="${PULL} -f rocm/Dockerfile ${NO_CACHE}"

OMNITRACE_DOCKER_OPTS="-f omnitrace/Dockerfile ${NO_CACHE} --build-arg DOCKER_USER=${DOCKER_USER} --build-arg OMNITRACE_BUILD_FROM_SOURCE=\"${OMNITRACE_BUILD_FROM_SOURCE}\" --build-arg PYTHON_VERSIONS=\"${PYTHON_VERSIONS}\""

OMNIPERF_DOCKER_OPTS="-f omniperf/Dockerfile ${NO_CACHE} --build-arg DOCKER_USER=${DOCKER_USER}"

TRAINING_DOCKER_OPTS="${NO_CACHE} --build-arg DOCKER_USER=${DOCKER_USER} --build-arg BUILD_DATE=$(date +'%Y-%m-%dT%H:%M:%SZ') --build-arg OG_BUILD_DATE=$(date -u +'%y-%m-%d') --build-arg BUILD_VERSION=1.1 --build-arg DISTRO=${DISTRO} --build-arg ADMIN_USERNAME=${ADMIN_USERNAME} --build-arg ADMIN_PASSWORD=${ADMIN_PASSWORD}"

TRAINING_DOCKER_OPTS="${TRAINING_DOCKER_OPTS} -f training/Dockerfile"

for ROCM_VERSION in ${ROCM_VERSIONS}
do
    if [ -d CacheFiles/${DISTRO}-${DISTRO_VERSION}-rocm-${ROCM_VERSION}/ ]; then
       USE_CACHED_APPS=1
    fi

    GENERAL_DOCKER_OPTS="--build-arg DISTRO=${DISTRO} --build-arg DISTRO_VERSION=${DISTRO_VERSION} --build-arg ROCM_VERSION=${ROCM_VERSION}"

# Building rocm docker
    if [ ! -d CacheFiles ]; then
       mkdir CacheFiles
    fi
    rm -rf CacheFiles/*.tgz
    if [ "${BUILD_OPENMPI}" = "0" ] && [ "${USE_CACHED_APPS}" = "1" ]; then
       if [ -f CacheFiles/${DISTRO}-${DISTRO_VERSION}-rocm-${ROCM_VERSION}-${AMDGPU_GFXMODEL}/ucx.tgz ]; then
          ln -s CacheFiles/${DISTRO}-${DISTRO_VERSION}-rocm-${ROCM_VERSION}-${AMDGPU_GFXMODEL}/ucx.tgz ucx.tgz
       fi
       if [ -f CacheFiles/${DISTRO}-${DISTRO_VERSION}-rocm-${ROCM_VERSION}-${AMDGPU_GFXMODEL}/openmpi.tgz ]; then
          ln -s CacheFiles/${DISTRO}-${DISTRO_VERSION}-rocm-${ROCM_VERSION}-${AMDGPU_GFXMODEL}/openmpi.tgz openmpi.tgz
       fi
    fi
    date > CacheFiles/timestamp
    verbose-build docker build ${OUTPUT_VERBOSITY} ${GENERAL_DOCKER_OPTS} ${ROCM_DOCKER_OPTS} \
       --build-arg AMDGPU_GFXMODEL=${AMDGPU_GFXMODEL} \
       --tag ${DOCKER_USER}/rocm:release-base-${DISTRO}-${DISTRO_VERSION}-rocm-${ROCM_VERSION} \
       .
    rm -rf CacheFiles/*.tgz

# Building omnitrace docker
    if [ "${BUILD_OMNITRACE_FROM_SOURCE}" = "0" ] && [ "${USE_CACHED_APPS}" = "1" ]; then
       if [ -f CacheFiles/${DISTRO}-${DISTRO_VERSION}-rocm-${ROCM_VERSION}-${AMDGPU_GFXMODEL}/omnitrace.tgz ]; then
          ln -s CacheFiles/${DISTRO}-${DISTRO_VERSION}-rocm-${ROCM_VERSION}-${AMDGPU_GFXMODEL}/omnitrace.tgz omnitrace.tgz
       fi
    fi
    date > CacheFiles/timestamp
    verbose-build docker build ${OUTPUT_VERBOSITY} ${GENERAL_DOCKER_OPTS} ${OMNITRACE_DOCKER_OPTS} \
       --build-arg AMDGPU_GFXMODEL=${AMDGPU_GFXMODEL} \
       -t ${DOCKER_USER}/omnitrace:release-base-${DISTRO}-${DISTRO_VERSION}-rocm-${ROCM_VERSION} \
       .
    rm -rf CacheFiles/*.tgz

# Building omniperf docker
    verbose-build docker build ${OUTPUT_VERBOSITY} ${GENERAL_DOCKER_OPTS} ${OMNIPERF_DOCKER_OPTS} \
       -t ${DOCKER_USER}/omniperf:release-base-${DISTRO}-${DISTRO_VERSION}-rocm-${ROCM_VERSION} \
       .

# Building training docker
    if [ "${USE_CACHED_APPS}" = "1" ]; then
       if [ "${BUILD_GCC_LATEST}" = "1" ]; then
          if [ -f CacheFiles/${DISTRO}-${DISTRO_VERSION}-rocm-${ROCM_VERSION}-${AMDGPU_GFXMODEL}/gcc-13.2.0.tgz ]; then
             ln -s CacheFiles/${DISTRO}-${DISTRO_VERSION}-rocm-${ROCM_VERSION}-${AMDGPU_GFXMODEL}/gcc-13.2.0.tgz gcc-13.2.0.tgz
          fi
       fi
       if [ "${BUILD_AOMP_LATEST}" = "1" ]; then
          if [ -f CacheFiles/${DISTRO}-${DISTRO_VERSION}-rocm-${ROCM_VERSION}-${AMDGPU_GFXMODEL}/aomp_19.0-0.tgz ]; then
             ln -s CacheFiles/${DISTRO}-${DISTRO_VERSION}-rocm-${ROCM_VERSION}-${AMDGPU_GFXMODEL}/aomp_19.0-0.tgz aomp_19.0-0.tgz
          fi
       fi
       if [ "${BUILD_LLVM_LATEST}" = "1" ]; then
          if [ -f CacheFiles/${DISTRO}-${DISTRO_VERSION}-rocm-${ROCM_VERSION}-${AMDGPU_GFXMODEL}/llvm-latest.tgz ]; then
             ln -s CacheFiles/${DISTRO}-${DISTRO_VERSION}-rocm-${ROCM_VERSION}-${AMDGPU_GFXMODEL}/llvm-latest.tgz llvm-latest.tgz
          fi
       fi
       if [ "${BUILD_CLACC_LATEST}" = "1" ]; then
          if [ -f CacheFiles/${DISTRO}-${DISTRO_VERSION}-rocm-${ROCM_VERSION}-${AMDGPU_GFXMODEL}/clacc_clang.tgz ]; then
             ln -s CacheFiles/${DISTRO}-${DISTRO_VERSION}-rocm-${ROCM_VERSION}-${AMDGPU_GFXMODEL}/clacc_clang.tgz clacc_clang.tgz
          fi
       fi
       if [ "${BUILD_OG_LATEST}" = "1" ]; then
          if [ -f CacheFiles/${DISTRO}-${DISTRO_VERSION}-rocm-${ROCM_VERSION}-${AMDGPU_GFXMODEL}/og13.tgz ]; then
             ln -s CacheFiles/${DISTRO}-${DISTRO_VERSION}-rocm-${ROCM_VERSION}-${AMDGPU_GFXMODEL}/og13.tgz og13.tgz
          fi
       fi
       if [ "${BUILD_PYTORCH}" = "1" ]; then
          if [ -f CacheFiles/${DISTRO}-${DISTRO_VERSION}-rocm-${ROCM_VERSION}-${AMDGPU_GFXMODEL}/pytorch.tgz ]; then
             ln -s CacheFiles/${DISTRO}-${DISTRO_VERSION}-rocm-${ROCM_VERSION}-${AMDGPU_GFXMODEL}/pytorch.tgz pytorch.tgz
          fi
       fi
       if [ "${BUILD_CUPY}" = "1" ]; then
          if [ -f CacheFiles/${DISTRO}-${DISTRO_VERSION}-rocm-${ROCM_VERSION}-${AMDGPU_GFXMODEL}/cupy.tgz ]; then
             ln -s CacheFiles/${DISTRO}-${DISTRO_VERSION}-rocm-${ROCM_VERSION}-${AMDGPU_GFXMODEL}/cupy.tgz cupy.tgz
          fi
       fi
    fi
    date > CacheFiles/timestamp
    verbose-build docker build ${OUTPUT_VERBOSITY} ${GENERAL_DOCKER_OPTS} ${TRAINING_DOCKER_OPTS} \
       --build-arg AMDGPU_GFXMODEL=${AMDGPU_GFXMODEL} \
       --build-arg BUILD_GCC_LATEST=${BUILD_GCC_LATEST} \
       --build-arg BUILD_AOMP_LATEST=${BUILD_AOMP_LATEST} \
       --build-arg BUILD_LLVM_LATEST=${BUILD_LLVM_LATEST} \
       --build-arg BUILD_OG_LATEST=${BUILD_OG_LATEST} \
       --build-arg BUILD_CLACC_LATEST=${BUILD_CLACC_LATEST} \
       --build-arg BUILD_PYTORCH=${BUILD_PYTORCH} \
       --build-arg BUILD_CUPY=${BUILD_CUPY} \
       --build-arg USE_CACHED_APPS=${USE_CACHED_APPS} \
       -t ${DOCKER_USER}/training:release-base-${DISTRO}-${DISTRO_VERSION}-rocm-${ROCM_VERSION} \
       -t training \
       .
    rm -rf CacheFiles/*.tgz

    if [ "${PUSH}" -ne 0 ]; then
        docker push ${CONTAINER}
    fi
done
