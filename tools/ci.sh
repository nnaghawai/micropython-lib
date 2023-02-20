#!/bin/bash

########################################################################################
# common "constants"
PACKAGE_INDEX_PATH=/tmp/micropython-lib-deploy

########################################################################################
# code formatting

function ci_code_formatting_setup {
    sudo apt-add-repository --yes --update ppa:pybricks/ppa
    sudo apt-get install uncrustify
    pip3 install black
    uncrustify --version
    black --version
}

function ci_code_formatting_run {
    tools/codeformat.py -v
}

########################################################################################
# build packages

function ci_build_packages_setup {
    git clone https://github.com/micropython/micropython.git /tmp/micropython

    # build mpy-cross (use -O0 to speed up the build)
    make -C /tmp/micropython/mpy-cross -j CFLAGS_EXTRA=-O0

    # check the required programs run
    /tmp/micropython/mpy-cross/build/mpy-cross --version
    python3 /tmp/micropython/tools/manifestfile.py --help
}

function ci_build_packages_check_manifest {
    for file in $(find -name manifest.py); do
        echo "##################################################"
        echo "# Testing $file"
        python3 /tmp/micropython/tools/manifestfile.py --lib . --compile $file
    done
}

function ci_build_packages_compile_index {
    python3 tools/build.py --micropython /tmp/micropython --output $PACKAGE_INDEX_PATH
}

function ci_push_package_index {
    set -euo pipefail

    # Note: This feature is opt-in, so this function is only run by GitHub
    # Actions if the MICROPY_PUBLISH_MIP_INDEX repository variable is set to a
    # "truthy" value in the "Secrets and variables" -> "Actions"
    # -> "Variables" setting of the GitHub repo.

    PAGES_PATH=/tmp/gh-pages

    if git fetch --depth=1 origin gh-pages; then
        git worktree add ${PAGES_PATH} gh-pages
        cd ${PAGES_PATH}
        NEW_BRANCH=0
    else
        echo "Creating gh-pages branch for $GITHUB_REPOSITORY..."
        git worktree add --force ${PAGES_PATH} HEAD
        cd ${PAGES_PATH}
        git switch --orphan gh-pages
        NEW_BRANCH=1
    fi

    DEST_PATH=${PAGES_PATH}/mip/${GITHUB_REF_NAME}
    if [ -d ${DEST_PATH} ]; then
        git rm -r ${DEST_PATH}
    fi
    mkdir -p ${DEST_PATH}
    cd ${DEST_PATH}

    cp -r ${PACKAGE_INDEX_PATH}/* .

    git add .
    git_bot_commit "Add CI built packages from commit ${GITHUB_SHA} of ${GITHUB_REF_NAME}"

    if [ "$NEW_BRANCH" -eq 0 ]; then
        # A small race condition exists here if another CI job pushes to
        # gh-pages at the same time, but this narrows the race to the time
        # between these two commands.
        git pull --rebase origin gh-pages
    fi
    git push origin gh-pages

    INDEX_URL="https://${GITHUB_REPOSITORY_OWNER}.github.io/$(echo ${GITHUB_REPOSITORY} | cut -d'/' -f2-)/mip/${GITHUB_REF_NAME}"

    echo ""
    echo "--------------------------------------------------"
    echo "Uploaded package files to GitHub Pages."
    echo ""
    echo "Unless GitHub Pages is disabled on this repo, these files can be installed remotely with:"
    echo ""
    echo "mpremote mip install --index ${INDEX_URL} PACKAGE_NAME"
    echo ""
    echo "or on the device as:"
    echo ""
    echo "import mip"
    echo "mip.install(PACKAGE_NAME, index=\"${INDEX_URL}\")"
}

function ci_cleanup_package_index()
{
    if ! git fetch --depth=1 origin gh-pages; then
        exit 0
    fi

    # Argument $1 is github.event.ref, passed in from workflow file.
    #
    # this value seems to be a REF_NAME, without heads/ or tags/ prefix. (Can't
    # use GITHUB_REF_NAME, this evaluates to the default branch.)
    DELETED_REF="$1"

    if [ -z "$DELETED_REF" ]; then
        echo "Bad DELETE_REF $DELETED_REF"
        exit 1  # Internal error with ref format, better than removing all mip/ directory in a commit
    fi

    # We need Actions to check out default branch and run tools/ci.sh, but then
    # we switch branches
    git switch gh-pages

    echo "Removing any published packages for ${DELETED_REF}..."
    if [ -d mip/${DELETED_REF} ]; then
        git rm -r mip/${DELETED_REF}
        git_bot_commit "Remove CI built packages from deleted ${DELETED_REF}"
        git pull --rebase origin gh-pages
        git push origin gh-pages
    else
        echo "Nothing to remove."
    fi
}

# Make a git commit with bot authorship
# Argument $1 is the commit message
function git_bot_commit {
    # Ref https://github.com/actions/checkout/discussions/479
    git config user.name 'github-actions[bot]'
    git config user.email 'github-actions[bot]@users.noreply.github.com'
    git commit -m "$1"
}
