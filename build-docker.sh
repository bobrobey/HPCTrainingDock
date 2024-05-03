#!/usr/bin/env bash

: ${DOCKER_USER:=$(whoami)}
: ${ROCM_VERSIONS:="5.0"}
: ${DISTRO:=ubuntu}
: ${DISTRO_VERSIONS:=20.04}
: ${PYTHON_VERSIONS:="8 9 10 11"}
: ${BUILD_CI:=""}
: ${PUSH:=0}
: ${PULL:=--pull}
: ${OUTPUT_VERBOSITY:=""}
: ${BUILD_AOMP_LATEST:="0"}
: ${BUILD_LLVM_LATEST:="0"}
: ${BUILD_GCC_LATEST:="0"}
: ${BUILD_OG_LATEST:="0"}
: ${BUILD_CLACC_LATEST:="0"}
: ${BUILD_PYTORCH_LATEST:="0"}
: ${BUILD_ALL_LATEST:="0"}
: ${RETRY:=3}
: ${NO_CACHE:=""}
: ${OMNITRACE_BUILD_FROM_SOURCE:=0}
: ${ADMIN_USERNAME:="admin"}
: ${ADMIN_PASSWORD:=""}
: ${USE_CACHED_APPS:=0}
: ${AMDGPU_GFXMODEL:=""}

set -e

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
    print_default_option build-pytorch-latest -- flag to build the latest version of pytorch
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

version-set()
{
        VERSION_MAJOR=$(echo ${DISTRO_VERSION} | sed 's/\./ /g' | awk '{print $1}')
        VERSION_MINOR=$(echo ${DISTRO_VERSION} | sed 's/\./ /g' | awk '{print $2}')
        VERSION_PATCH=$(echo ${DISTRO_VERSION} | sed 's/\./ /g' | awk '{print $3}')

        ROCM_MAJOR=$(echo ${ROCM_VERSION} | sed 's/\./ /g' | awk '{print $1}')
        ROCM_MINOR=$(echo ${ROCM_VERSION} | sed 's/\./ /g' | awk '{print $2}')
        ROCM_PATCH=$(echo ${ROCM_VERSION} | sed 's/\./ /g' | awk '{print $3}')
        if [ -n "${ROCM_PATCH}" ]; then
            ROCM_VERSN=$(( (${ROCM_MAJOR}*10000)+(${ROCM_MINOR}*100)+(${ROCM_PATCH}) ))
            ROCM_SEP="."
        else
            ROCM_VERSN=$(( (${ROCM_MAJOR}*10000)+(${ROCM_MINOR}*100) ))
            ROCM_SEP=""
        fi

        if [ "x${ROCM_PATCH}" == "x" ]; then
           AMDGPU_INSTALL_VERSION=${ROCM_MAJOR}.${ROCM_MINOR}.${ROCM_MAJOR}0${ROCM_MINOR}00-1
           AMDGPU_ROCM_VERSION=${ROCM_MAJOR}.${ROCM_MINOR}
	elif [ "${ROCM_PATCH}" == "0" ]; then
           AMDGPU_INSTALL_VERSION=${ROCM_MAJOR}.${ROCM_MINOR}.${ROCM_MAJOR}0${ROCM_MINOR}0${ROCM_PATCH}-1
           AMDGPU_ROCM_VERSION=${ROCM_MAJOR}.${ROCM_MINOR}
	else
           AMDGPU_INSTALL_VERSION=${ROCM_MAJOR}.${ROCM_MINOR}.${ROCM_MAJOR}0${ROCM_MINOR}0${ROCM_PATCH}-1
           AMDGPU_ROCM_VERSION=${ROCM_MAJOR}.${ROCM_MINOR}.${ROCM_PATCH}
	fi
}

ubuntu-set()
{
            ROCM_REPO_DIST="ubuntu"
            case "${ROCM_VERSION}" in
                4.1* | 4.0*)
                    ROCM_REPO_DIST="xenial"
                    ;;
                5.3* | 5.4* | 5.5* | 5.6* | 5.7*)
                    case "${DISTRO_VERSION}" in
                        22.04)
                            ROCM_REPO_DIST="jammy"
                            ;;
                        20.04)
                            ROCM_REPO_DIST="focal"
                            ;;
                        18.04)
                            ROCM_REPO_DIST="bionic"
                            ;;
                        *)
                            ;;
                    esac
                    ;;
                6.0* | 6.1*)
                    case "${DISTRO_VERSION}" in
                        22.04)
                            ROCM_REPO_DIST="jammy"
                            ;;
                        20.04)
                            ROCM_REPO_DIST="focal"
                            ;;
                        *)
                            ;;
                    esac
                    ;;
                *)
                    ;;
            esac
}

rhel-set()
{
            if [ -z "${VERSION_MINOR}" ]; then
                send-error "Please provide a major and minor version of the OS. Supported: >= 8.7, <= 9.1"
            fi

            # Components used to create the sub-URL below
            #   set <OS-DISTRO_VERSION> in amdgpu-install/<ROCM-VERSION>/rhel/<OS-DISTRO_VERSION>
            RPM_PATH=${VERSION_MAJOR}.${VERSION_MINOR}
            RPM_TAG=".el${VERSION_MAJOR}"

            # set the sub-URL in https://repo.radeon.com/amdgpu-install/<sub-URL>
            case "${ROCM_VERSION}" in
                5.4 | 5.4.*)
                    ROCM_RPM=${ROCM_VERSION}/rhel/${RPM_PATH}/amdgpu-install-${ROCM_MAJOR}.${ROCM_MINOR}.${ROCM_VERSN}-1${RPM_TAG}.noarch.rpm
                    ;;
                5.3 | 5.3.*)
                    ROCM_RPM=${ROCM_VERSION}/rhel/${RPM_PATH}/amdgpu-install-${ROCM_MAJOR}.${ROCM_MINOR}.${ROCM_VERSN}-1${RPM_TAG}.noarch.rpm
                    ;;
                5.2 | 5.2.* | 5.1 | 5.1.* | 5.0 | 5.0.* | 4.*)
                    send-error "Invalid ROCm version ${ROCM_VERSION}. Supported: >= 5.3.0, <= 5.4.x"
                    ;;
                0.0)
                    ;;
                *)
                    send-error "Unsupported combination :: ${DISTRO}-${DISTRO_VERSION} + ROCm ${ROCM_VERSION}"
                    ;;
            esac

            # use Rocky Linux as a base image for RHEL builds
            DISTRO_BASE_IMAGE=rockylinux

            #verbose-build docker build . ${PULL} -f ${DOCKER_FILE} --tag ${CONTAINER} --build-arg DISTRO=${DISTRO_BASE_IMAGE} --build-arg DISTRO_VERSION=${DISTRO_VERSION} --build-arg ROCM_VERSION=${ROCM_VERSION} --build-arg AMDGPU_RPM=${ROCM_RPM} --build-arg PYTHON_VERSIONS=\"${PYTHON_VERSIONS}\"

#	    ROCM_DOCKER_OPTS="${ROCM_DOCKER_OPTS} --tag ${CONTAINER} --build-arg DISTRO=${DISTRO_BASE_IMAGE} --build-arg DISTRO_VERSION=${DISTRO_VERSION} --build-arg ROCM_VERSION=${ROCM_VERSION} --build-arg AMDGPU_RPM=${ROCM_RPM}"
}

opensuse-set()
{
            case "${DISTRO_VERSION}" in
                15.*)
                    DISTRO_IMAGE="opensuse/leap"
                    echo "DISTRO_IMAGE: ${DISTRO_IMAGE}"
                    ;;
                *)
                    send-error "Invalid opensuse version ${DISTRO_VERSION}. Supported: 15.x"
                    ;;
            esac
            case "${ROCM_VERSION}" in
                5.4 | 5.4.*)
                    ROCM_RPM=${ROCM_VERSION}/sle/${DISTRO_VERSION}/amdgpu-install-${ROCM_MAJOR}.${ROCM_MINOR}.${ROCM_VERSN}-1.noarch.rpm
                    ;;
                5.3 | 5.3.*)
                    ROCM_RPM=${ROCM_VERSION}/sle/${DISTRO_VERSION}/amdgpu-install-${ROCM_MAJOR}.${ROCM_MINOR}.${ROCM_VERSN}-1.noarch.rpm
                    ;;
                5.2 | 5.2.*)
                    ROCM_RPM=22.20${ROCM_SEP}${ROCM_PATCH}/sle/${DISTRO_VERSION}/amdgpu-install-22.20.${ROCM_VERSN}-1.noarch.rpm
                    ;;
                5.1 | 5.1.*)
                    ROCM_RPM=22.10${ROCM_SEP}${ROCM_PATCH}/sle/15/amdgpu-install-22.10${ROCM_SEP}${ROCM_PATCH}.${ROCM_VERSN}-1.noarch.rpm
                    ;;
                5.0 | 5.0.*)
                    ROCM_RPM=21.50${ROCM_SEP}${ROCM_PATCH}/sle/15/amdgpu-install-21.50${ROCM_SEP}${ROCM_PATCH}.${ROCM_VERSN}-1.noarch.rpm
                    ;;
                4.5 | 4.5.*)
                    ROCM_RPM=21.40${ROCM_SEP}${ROCM_PATCH}/sle/15/amdgpu-install-21.40${ROCM_SEP}${ROCM_PATCH}.${ROCM_VERSN}-1.noarch.rpm
                    ;;
                0.0)
                    ;;
                *)
                    send-error "Unsupported combination :: ${DISTRO}-${DISTRO_VERSION} + ROCm ${ROCM_VERSION}"
                ;;
            esac
            PERL_REPO="SLE_${VERSION_MAJOR}_SP${VERSION_MINOR}"
	    #verbose-build docker build . ${PULL} -f rocm/${DOCKER_FILE} --tag ${CONTAINER} --build-arg DISTRO=${DISTRO_IMAGE} --build-arg DISTRO_VERSION=${DISTRO_VERSION} --build-arg ROCM_VERSION=${ROCM_VERSION} --build-arg AMDGPU_RPM=${ROCM_RPM} --build-arg PERL_REPO=${PERL_REPO} --build-arg PYTHON_VERSIONS=\"${PYTHON_VERSIONS}\"

#	    ROCM_DOCKER_OPTS="${ROCM_DOCKER_OPTS} --tag ${CONTAINER} --build-arg DISTRO=${DISTRO_IMAGE} --build-arg DISTRO_VERSION=${DISTRO_VERSION} --build-arg ROCM_VERSION=${ROCM_VERSION} --build-arg AMDGPU_RPM=${ROCM_RPM} --build-arg PERL_REPO=${PERL_REPO}"
}

reset-last

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
        "--build-pytorch-latest")
            BUILD_PYTORCH_LATEST="1"
            reset-last
            ;;
        "--build-all-latest")
            BUILD_ALL_LATEST="1"
            BUILD_AOMP_LATEST="1"
            #BUILD_LLVM_LATEST="1"
            BUILD_GCC_LATEST="1"
            #BUILD_OG_LATEST="1"
            #BUILD_CLACC_LATEST="1"
            BUILD_PYTORCH_LATEST="1"
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

DOCKER_FILE="Dockerfile.${DISTRO}"

if [ -n "${BUILD_CI}" ]; then DOCKER_FILE="${DOCKER_FILE}.ci"; fi
#if [ ! -f ${DOCKER_FILE} ]; then cd docker; fi
if [ ! -f rocm/${DOCKER_FILE} ]; then send-error "File \"${DOCKER_FILE}\" not found"; fi

ROCM_DOCKER_OPTS="${PULL} -f rocm/${DOCKER_FILE}.mod ${NO_CACHE} --build-arg DISTRO=${DISTRO} --build-arg PYTHON_VERSIONS=\"${PYTHON_VERSIONS}\""

OMNITRACE_DOCKER_OPTS="-f omnitrace/Dockerfile ${NO_CACHE} --build-arg DOCKER_USER=${DOCKER_USER} --build-arg OMNITRACE_BUILD_FROM_SOURCE=\"${OMNITRACE_BUILD_FROM_SOURCE}\" --build-arg PYTHON_VERSIONS=\"${PYTHON_VERSIONS}\""

OMNIPERF_DOCKER_OPTS="-f omniperf/Dockerfile ${NO_CACHE} --build-arg DOCKER_USER=${DOCKER_USER}"

TRAINING_DOCKER_OPTS="${NO_CACHE} --build-arg DOCKER_USER=${DOCKER_USER} --build-arg BUILD_DATE=$(date +'%Y-%m-%dT%H:%M:%SZ') --build-arg OG_BUILD_DATE=$(date -u +'%y-%m-%d') --build-arg BUILD_VERSION=1.1 --build-arg DISTRO=${DISTRO} --build-arg ADMIN_USERNAME=${ADMIN_USERNAME} --build-arg ADMIN_PASSWORD=${ADMIN_PASSWORD}"

TRAINING_DOCKER_OPTS="${TRAINING_DOCKER_OPTS} -f training/Dockerfile.mod"

for DISTRO_VERSION in ${DISTRO_VERSIONS}
do
    for ROCM_VERSION in ${ROCM_VERSIONS}
    do
        cp rocm/Dockerfile.ubuntu rocm/Dockerfile.ubuntu.mod
        if [ -f CacheFiles/${DISTRO}-${DISTRO_VERSION}-rocm-${ROCM_VERSION}/ucx.tgz ]; then
           sed -i -e "/ucx.tgz/s/^#//" rocm/Dockerfile.ubuntu.mod
        fi
        if [ -f CacheFiles/${DISTRO}-${DISTRO_VERSION}-rocm-${ROCM_VERSION}/openmpi.tgz ]; then
           sed -i -e "/openmpi.tgz/s/^#//" rocm/Dockerfile.ubuntu.mod
        fi

        cp training/Dockerfile training/Dockerfile.mod
        if [ "${BUILD_GCC_LATEST}" = "1" ]; then
           if [ -f CacheFiles/${DISTRO}-${DISTRO_VERSION}-rocm-${ROCM_VERSION}/gcc-13.2.0.tgz ]; then
              sed -i -e "/gcc-13.2.0.tgz/s/^#//" training/Dockerfile.mod
           fi
        fi
        if [ "${BUILD_AOMP_LATEST}" = "1" ]; then
           if [ -f CacheFiles/${DISTRO}-${DISTRO_VERSION}-rocm-${ROCM_VERSION}/aomp_19.0-0.tgz ]; then
              sed -i -e "/aomp_19.0-0.tgz/s/^#//" training/Dockerfile.mod
           fi
        fi
        if [ "${BUILD_LLVM_LATEST}" = "1" ]; then
           if [ -f CacheFiles/${DISTRO}-${DISTRO_VERSION}-rocm-${ROCM_VERSION}/llvm-latest.tgz ]; then
              sed -i -e "/llvm-latest.tgz/s/^#//" training/Dockerfile.mod
           fi
        fi
        if [ "${BUILD_CLACC_LATEST}" = "1" ]; then
           if [ -f CacheFiles/${DISTRO}-${DISTRO_VERSION}-rocm-${ROCM_VERSION}/clacc_clang.tgz ]; then
              sed -i -e "/clacc_clang.tgz/s/^#//" training/Dockerfile.mod
           fi
        fi
        if [ "${BUILD_OG_LATEST}" = "1" ]; then
           if [ -f CacheFiles/${DISTRO}-${DISTRO_VERSION}-rocm-${ROCM_VERSION}/og13.tgz ]; then
              sed -i -e "/og13.tgz/s/^#//" training/Dockerfile.mod
              sed -i -e "/og13module.tgz/s/^#//" training/Dockerfile.mod
           fi
        fi
        if [ "${BUILD_PYTORCH_LATEST}" = "1" ]; then
           if [ -f CacheFiles/${DISTRO}-${DISTRO_VERSION}-rocm-${ROCM_VERSION}/pytorch.tgz ]; then
              sed -i -e "/pytorch.tgz/s/^#//" training/Dockerfile.mod
           fi
        fi

	version-set

        if [ "${DISTRO}" = "ubuntu" ]; then
	    ubuntu-set
        elif [ "${DISTRO}" = "rhel" ]; then
	    rhel-set
        elif [ "${DISTRO}" = "opensuse" ]; then
	    opensuse-set
        fi

	GENERAL_DOCKER_OPTS="--build-arg DISTRO_VERSION=${DISTRO_VERSION} --build-arg ROCM_VERSION=${ROCM_VERSION}"
	if [ "x${AMDGPU_GFXMODEL}" = "x" ]; then
	   AMDGPU_GFXMODEL=`rocminfo | grep gfx | sed -e 's/Name://' | head -1 |sed 's/ //g'`
	fi

        verbose-build docker build ${OUTPUT_VERBOSITY} ${GENERAL_DOCKER_OPTS} ${ROCM_DOCKER_OPTS} \
	   --build-arg ROCM_REPO_DIST=${ROCM_REPO_DIST} \
	   --build-arg AMDGPU_INSTALL_VERSION=${AMDGPU_INSTALL_VERSION} \
	   --build-arg AMDGPU_ROCM_VERSION=${AMDGPU_ROCM_VERSION} \
	   --build-arg AMDGPU_GFXMODEL=${AMDGPU_GFXMODEL} \
	   --tag ${DOCKER_USER}/rocm:release-base-${DISTRO}-${DISTRO_VERSION}-rocm-${ROCM_VERSION} \
	   .

        verbose-build docker build ${OUTPUT_VERBOSITY} ${GENERAL_DOCKER_OPTS} ${OMNITRACE_DOCKER_OPTS} \
	   --build-arg AMDGPU_GFXMODEL=${AMDGPU_GFXMODEL} \
	   -t ${DOCKER_USER}/omnitrace:release-base-${DISTRO}-${DISTRO_VERSION}-rocm-${ROCM_VERSION} \
	   .

        verbose-build docker build ${OUTPUT_VERBOSITY} ${GENERAL_DOCKER_OPTS} ${OMNIPERF_DOCKER_OPTS} \
	   -t ${DOCKER_USER}/omniperf:release-base-${DISTRO}-${DISTRO_VERSION}-rocm-${ROCM_VERSION} \
	   .

        verbose-build docker build ${OUTPUT_VERBOSITY} ${GENERAL_DOCKER_OPTS} ${TRAINING_DOCKER_OPTS} \
	   --build-arg AMDGPU_GFXMODEL=${AMDGPU_GFXMODEL} \
	   --build-arg BUILD_GCC_LATEST=${BUILD_GCC_LATEST} \
	   --build-arg BUILD_AOMP_LATEST=${BUILD_AOMP_LATEST} \
	   --build-arg BUILD_LLVM_LATEST=${BUILD_LLVM_LATEST} \
	   --build-arg BUILD_OG_LATEST=${BUILD_OG_LATEST} \
	   --build-arg BUILD_CLACC_LATEST=${BUILD_CLACC_LATEST} \
	   --build-arg BUILD_PYTORCH_LATEST=${BUILD_PYTORCH_LATEST} \
	   --build-arg USE_CACHED_APPS=${USE_CACHED_APPS} \
	   -t ${DOCKER_USER}/training:release-base-${DISTRO}-${DISTRO_VERSION}-rocm-${ROCM_VERSION} \
	   -t training \
	   .

	rm -f rocm/Dockerfile.ubuntu.mod training/Dockerfile.mod

        if [ "${PUSH}" -ne 0 ]; then
            docker push ${CONTAINER}
        fi
    done
done