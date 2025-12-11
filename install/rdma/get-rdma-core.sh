#! /bin/bash
OPTIONS="v:G:R:P:"
LONGOPTIONS="version:,rdma-git:,rdma-ref:,patch-url;"
SCRIPT_DIR=$(readlink -f "$(dirname "$0")")
# install/.cache/
CACHE_DIR="$(dirname "$SCRIPT_DIR")/.cache"
[[ -d "$CACHE_DIR" ]] || mkdir -p cache

# Parse the options
PARSED=$(getopt --options=$OPTIONS --longoptions=$LONGOPTIONS --name "$0" -- "$@")
# shellcheck disable=SC2181
if [[ $? -ne 0 ]]; then
    # If getopt has complained about wrong arguments, print the error message and exit
    exit 2
fi

# Use eval to properly handle the parsed options
eval set -- "$PARSED"

# Process the options
while true; do
    case "$1" in
        -v|--version)
            RDMA_CORE_VERSION="$2"
            shift 2
            ;;
        -G|--rdma-git)
            RDMA_GIT_REPO="$2"
            shift 2
            ;;
        -R|--rdma-ref)
            RDMA_GIT_REF="$2"
            shift 2
            ;;
        -P|--patch-url)
            PATCH_URL="$2"
            shift 2
            ;;
        --)
            shift
            break
            ;;
        *)
            echo "Unknown option: $1"
            exit 3
            ;;
    esac
done
# git checkout
if [[ -n "$RDMA_GIT_REPO" ]]; then
    RDMA_SOURCE_DIR="./rdma-core"
    if [[ -n "$RDMA_CORE_REF" ]]; then
            git clone --depth 1 "$RDMA_GIT_REPO" -b "$RDMA_GIT_REF" "$RDMA_SOURCE_DIR" || { 
            echo "Could not clone repo '$RDMA_GIT_REPO' w branch '$RDMA_GIT_REF'!" 1>&2;
            exit 1; 
        }
    else 
        git clone "$RDMA_GIT_REPO" "$RDMA_SOURCE_DIR" || { 
            echo "Could not clone repo '$RDMA_GIT_REPO'!" 1>&2;
            exit 1; 
        }
    fi
    [[ -d "$RDMA_SOURCE_DIR" ]] || { 
        echo "could not find rdma source after clone!" 1>&2; 
        ls -la 1>&2; 
        exit 1;
    }
    # note the directory name for later
    echo "$RDMA_SOURCE_DIR" > "$CACHE_DIR"/rdma_src_dir;
else # tar install

    if [[ -z "$RDMA_CORE_VERSION" ]]; then
        RDMA_CORE_VERSION="58.8"
    fi
    RDMA_CORE_TAR_LINK="https://github.com/linux-rdma/rdma-core/releases/download/v$RDMA_CORE_VERSION/rdma-core-$RDMA_CORE_VERSION.tar.gz"
    wget  "$RDMA_CORE_TAR_LINK" \
    || { echo "wget for rdma-core tarball failed!"; exit 1; }

    RDMA_CORE_TAR_PATH=$(basename "$RDMA_CORE_TAR_LINK")
    tar xzvf "$RDMA_CORE_TAR_PATH" \
    || { echo "tar expand for rdma-core tarball failed!"; exit 1; }

    RDMA_TAR_DIR=$(tar --list --file "$RDMA_CORE_TAR_PATH" | cut -d '/' -f 1 | uniq )
    echo "$RDMA_TAR_DIR" > "$CACHE_DIR"/rdma_src_dir;
    RDMA_SOURCE_DIR="$RDMA_TAR_DIR"
fi

# apply a patch, if one was provided
if [[ -n "$PATCH_URL" ]]; then
    pushd "$RDMA_SOURCE_DIR" || { echo "Could not pushd to rdma source dir $RDMA_SOURCE_DIR!" 1>&2; exit 1;}
    PATCH_FILE=$(basename "$PATCH_URL")
    wget -sSL "$PATCH_URL" -O "$PATCH_FILE" || { echo "Could not download $PATCH_URL" 1>&2; exit 1; }
    git apply "$PATCH_FILE" || { echo "Could not apply path file $PATCH_FILE" 1>&2; exit 1; }
    popd || { echo "Could not leave rdma core directory at $RDMA_SOURCE_DIR"; exit 1; }
fi

exit 0
