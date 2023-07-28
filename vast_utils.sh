#!/bin/bash

# We want to be able to return to the previous virtual env if the user
# runs a command in this one.
export VIRTUAL_ENV_STACK;

# Bunch of helpful info about the current vast.ai instance this dir is using.
export VAST_INSTANCE_LABEL
export VAST_INSTANCE
export VAST_INSTANCE_ID
export VAST_SSH_HOST
export VAST_SSH_PORT
export VAST_SSH_URL

function project_name {
    echo "$(basename "$(realpath .)")";
}

function vast_venv_location {
    echo "$UTILS_FOR_VAST_LOCATION/venv";
}

function vast_requirements_location {
    echo "$UTILS_FOR_VAST_LOCATION/requirements.txt";
}

function virtual_env_stack_push {
    NEXT="$1";
    if [[ "${VIRTUAL_ENV_STACK:-}" == "" ]]; then
        export VIRTUAL_ENV_STACK="$NEXT"
    else
        export VIRTUAL_ENV_STACK="$VIRTUAL_ENV_STACK:$NEXT"
    fi
}

function virtual_env_stack_pop {
    if [[ "${VIRTUAL_ENV_STACK:-}" == "" ]]; then
        return 1;
    else
        export VIRTUAL_ENV_STACK="$(echo "$VIRTUAL_ENV_STACK" \
            | sed 's/^[^:]*$//g;s/[:][^:]*$//g'
        )"
    fi
}

function virtual_env_stack_peek {
    if [[ "${VIRTUAL_ENV_STACK:-}" == "" ]]; then
        return 1;
    else
        echo "$(echo "$VIRTUAL_ENV_STACK" | sed 's/^.*://g')"
    fi
}

function vast_venv_up {
    if [[ "${VIRTUAL_ENV:-}" != "" ]]; then
        PREV_VIRTUAL_ENV="$VIRTUAL_ENV";
        virtual_env_stack_push "$VIRTUAL_ENV";
    fi
    if [ ! -d "$(vast_venv_location)" ]; then
        echo "$(vast_venv_location) does not exist, creating";
        python3 -m venv "$(vast_venv_location)"
    fi
    if [[ "${VIRTUAL_ENV:-}" != "$(realpath "$(vast_venv_location)")" ]]; then
        source "$(vast_venv_location)/bin/activate"
    fi
    if ! cmp --silent <(cat "$(vast_requirements_location)") <(pip freeze); then
        echo "$(vast_venv_location) does not have all requirements installed, installing.";
        pip install -r "$(vast_requirements_location)"
        pip freeze > "$(vast_requirements_location)"
    fi
}

function vast_venv_down {
    deactivate
    PREV_VIRTUAL_ENV="$(virtual_env_stack_peek)";
    virtual_env_stack_pop
    if [[ "$PREV_VIRTUAL_ENV" != "" ]]; then
        source "$PREV_VIRTUAL_ENV/bin/activate";
        export PREV_VIRTUAL_ENV="";
    fi
}

function vast_ensure_authed {
    # Have user enter api key if they have not already
    vast_venv_up
    if vastai show user | grep --silent '401: This action requires login'; then
        echo "Not logged into vast.ai. Please enter an api key from https://cloud.vast.ai/account/"
        echo -n 'API key: '
        read -s VASTAI_API_KEY;
        vastai set api-key "$VASTAI_API_KEY";
    fi

    # Ensure user is authed with vast.ai
    if ! vastai show user --raw | grep --silent email; then
        echo "Failure to authenticate with vast.ai. Aborting.";
        vastai show user --raw
        vast_venv_down
        return 1;
    else
        vast_venv_down
    fi
}

function json_extract_field {
    JSON="$1"
    FIELD="$2"
    VALUE="$(echo "$JSON" | python3 -c 'import sys, json; print(json.loads(sys.stdin.read())[sys.argv[1]])' "$FIELD")"

    echo "$VALUE";
}

function vast_default_label {
    # Unique label for this local directory -- later also add in the params
    # of the particular job we want to run here.
    echo "$(project_name)-$(realpath . | sha256sum | awk '{print $1}')";
}

function vast_get_instance_by_label {
    LABEL="$1";
    vast_venv_up
    VAST_INSTANCE="$(
        vastai show instances --raw \
            | python3 -c "$(echo \
                'import sys, json;' \
                'label = sys.argv[1];' \
                '[' \
                '    print(json.dumps(it, indent="  "))' \
                '    for it in json.loads(sys.stdin.read())[:1]' \
                '    if it["label"] == label' \
            ']')" "$LABEL"
    )";
    export VAST_INSTANCE;
    export VAST_INSTANCE_ID="$(json_extract_field "$VAST_INSTANCE" "id")"
    export VAST_INSTANCE_LABEL="$LABEL";
    vast_venv_down
}

function vast_ensure_instance {
    LABEL="${1:-${VAST_INSTANCE_LABEL:-$(vast_default_label)}}"
    vast_venv_up
    vast_ensure_authed
    vast_get_instance_by_label "$LABEL";
    if [[ "$VAST_INSTANCE_ID" == "" ]]; then
        echo "No vast.ai instance active. Searching offers for a suitable machine.";
        INSTANCE_ID_TO_RENT="$(
            vastai search offers "$(echo \
                'reliability>=0.98' \
                'disk_space>=100' \
                'gpu_name=RTX_3090' \
                'dph<=0.25' \
                'duration>=1' \
                'cuda_vers>=11.8' \
                'inet_up>=100' \
                'inet_down>=100' \
                'direct_port_count>=4' \
                'geolocation in [US,CA]'
            )" --on-demand --order 'dph' --raw | python3 -c "$(echo \
                'import sys, json;' \
                'print(json.loads(sys.stdin.read())[0]["id"])'
            )"
        )";

        echo "Renting vast.ai instance $INSTANCE_ID_TO_RENT";
        CREATE_RESULT="$(vastai create instance "$INSTANCE_ID_TO_RENT" \
            --image tensorflow/tensorflow:2.13.0-gpu \
            --disk 100 \
            --label "$LABEL" \
            --raw
        )"

        vast_get_instance_by_label "$LABEL";
    else
        echo "Found existing vast.ai instance $VAST_INSTANCE_ID";
    fi


    if [[ "$VAST_INSTANCE_ID" == "" ]]; then
        echo "No vast.ai instance active. Aborting."
        vast_venv_down
        return 1;
    else
        export VAST_INSTANCE_LABEL="$LABEL";
        export VAST_SSH_HOST="$(json_extract_field "$VAST_INSTANCE" "ssh_host")"
        export VAST_SSH_PORT="$(json_extract_field "$VAST_INSTANCE" "ssh_port")"
        export VAST_SSH_URL="ssh://root@${VAST_SSH_HOST}:${VAST_SSH_PORT}"
        vast_venv_down
    fi
}

function vast_wait_for_ready_instance {
    LABEL="${1:-${VAST_INSTANCE_LABEL:-$(vast_default_label)}}"
    vast_venv_up
    INSTANCE_STATUS="$(json_extract_field "$VAST_INSTANCE" "actual_status")"
    DELAY=5;
    while [[ "$INSTANCE_STATUS" != "running" ]]; do
        echo "Instance not ready yet. Waiting $DELAY seconds"
        sleep "$DELAY";
        DELAY="$((DELAY+5))"
        vast_ensure_instance
        INSTANCE_STATUS="$(json_extract_field "$VAST_INSTANCE" "actual_status")"

        if [[ "$INSTANCE_STATUS" == "running" ]]; then
            VAST_KNOWN_KEY="$(ssh-keyscan -p "$VAST_SSH_PORT" "$VAST_SSH_HOST" 2> /dev/null)";
            if ! grep -Fq "$VAST_KNOWN_KEY" "$HOME/.ssh/known_hosts"; then
                echo "$VAST_KNOWN_KEY" >> "$HOME/.ssh/known_hosts";
                if ! ssh "$VAST_SSH_URL" "true"; then
                    INSTANCE_STATUS="ssh_failing"
                fi
            else
                INSTANCE_STATUS="waiting_for_ssh"
            fi
        fi
    done

    vast_venv_down
}

function vast_setup_auto_remote {
    PROJECT_NAME="$(project_name)";

    # Configure such that any time you git push vast main
    # it immediately updates on remote
    vast_venv_up
    vast_ensure_instance
    vast_wait_for_ready_instance
    printf -v PROJECT_DIR_Q '/workspace/%q' "$(project_name)";
    printf -v PROJECT_GIT_DIR_Q '/workspace/%q.git' "$(project_name)";
    ssh -o LogLevel=error "$VAST_SSH_URL" "
        set -euxo pipefail

        touch ~/.no_auto_tmux

        # nvidia is rotating keys, and being annoying about it.
        # source /etc/lsb-release;
        # apt-key del 7fa2af80;
        # apt-key adv --fetch-keys \"https://developer.download.nvidia.com/compute/cuda/repos/\${DISTRIB_ID,,}\${DISTRIB_RELEASE//./}/\$(uname -m)/3bf863cc.pub\"
        # curl -sL 'http://keyserver.ubuntu.com/pks/lookup?op=get&search=0xF60F4B3D7FA2AF80' | apt-key add --

        # Use deadsnakes Python 3.11, because vast uses ubuntu 16.04
        add-apt-repository -y ppa:deadsnakes/ppa;
        apt-get update;
        apt-get install -y python3.11 python3.11-venv;

        mkdir -p ${PROJECT_GIT_DIR_Q};
        cd ${PROJECT_GIT_DIR_Q};
        git init --bare;

        mkdir -p ${PROJECT_DIR_Q};
        cd ${PROJECT_DIR_Q};
        git init;
        git remote add origin ${PROJECT_GIT_DIR_Q};

        cd ${PROJECT_GIT_DIR_Q};
        echo '#!/bin/sh'                      > hooks/post-receive;
        printf \"cd %q\\n\" ${PROJECT_DIR_Q} >> hooks/post-receive;
        echo 'unset GIT_DIR'                 >> hooks/post-receive;
        echo 'git pull origin main'          >> hooks/post-receive;
        chmod +x hooks/post-receive;
    ";
    git remote remove vast || true
    git remote add vast "${VAST_SSH_URL}${PROJECT_GIT_DIR_Q}"
    git push vast main
    ssh -o LogLevel=error "$VAST_SSH_URL" "
        set -euxo pipefail

        cd ${PROJECT_DIR_Q};
        python3.11 -m venv venv
        source venv/bin/activate

        if [ -f setup.py ]; then
            pip install .
        elif [ -f requirements.txt ]; then
            pip install -r requirements.txt
        fi
    ";
    vast_venv_down
}

function vast_run {
    vast_venv_up
    if [[ "${VAST_INSTANCE_ID:-}" == "" ]]; then
        echo "No vast instance to run command in";
        return 1;
    fi
    printf -v PROJECT_DIR_Q '/workspace/%q' "$(project_name)";
    printf -v CMD_Q '%q ' "$@";
    ssh -o LogLevel=error -t "$VAST_SSH_URL" "
        cd $PROJECT_DIR_Q;
        source venv/bin/activate;
        $CMD_Q
    "
    vast_venv_down
}


function vast_destroy_literally_all_the_instances_on_my_account_and_all_associated_data {
    vast_venv_up
    INSTANCE_IDS="$(vastai show instances --raw \
        | python3 -c "$(echo \
            'import sys, json;' \
            '[' \
            '    print(json.dumps(it["id"], indent="  "))' \
            '    for it in json.loads(sys.stdin.read())' \
        ']')"
    )"
    for INSTANCE_ID in $(echo $INSTANCE_IDS); do
        if [[ "$INSTANCE_ID" != "" ]]; then
            vastai destroy instance "$INSTANCE_ID"
        fi
    done
    vast_venv_down
}
