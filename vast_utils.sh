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

function vast_use_instance_by_label {
    LABEL="$1";
    vast_venv_up
    VAST_INSTANCE="$(
        vastai show instances --raw \
            | python3 -c "$(echo \
                'import sys, json;' \
                'label = sys.argv[1];' \
                '[' \
                '    print(json.dumps(it, indent="  "))' \
                '    for it in [
                        inst for inst in json.loads(sys.stdin.read())' \
                '       if inst["label"] == label' \
                '    ][:1]' \
            ']')" "$LABEL"
    )";
    export VAST_INSTANCE;
    export VAST_INSTANCE_ID="$(json_extract_field "$VAST_INSTANCE" "id")"
    export VAST_INSTANCE_LABEL="$LABEL";
    export VAST_SSH_HOST="$(json_extract_field "$VAST_INSTANCE" "ssh_host")"
    export VAST_SSH_PORT="$(json_extract_field "$VAST_INSTANCE" "ssh_port")"
    export VAST_SSH_URL="ssh://root@${VAST_SSH_HOST}:${VAST_SSH_PORT}"
    vast_venv_down
}

function vast_ensure_instance {
    LABEL="${1:-${VAST_INSTANCE_LABEL:-$(vast_default_label)}}"
    vast_venv_up
    vast_ensure_authed
    vast_use_instance_by_label "$LABEL";
    if [[ "$VAST_INSTANCE_ID" == "" ]]; then
        echo "No vast.ai instance active. Searching offers for a suitable machine.";
        VAST_OFFERS="$(vastai search offers "$(echo \
            'reliability>=0.98' \
            'disk_space>=100' \
            'gpu_name=RTX_3090' \
            'dph<=0.25' \
            'duration>=1' \
            'cuda_vers>=11.8' \
            'inet_up>=20' \
            'inet_down>=100'
        )" --on-demand --order 'dph' --raw)";
        INSTANCE_ID_TO_RENT="$(
            echo "$VAST_OFFERS" | python3 -c "$(echo \
                'import sys, json;' \
                'print(json.loads(sys.stdin.read())[0]["id"])'
            )"
        )";
        if [[ "$?" != "0" ]]; then
            echo -e "Malformed vast offers: search returned\n${VAST_OFFERS}\n";
            return 1;
        fi

        echo "Renting vast.ai instance $INSTANCE_ID_TO_RENT";
        CREATE_RESULT="$(vastai create instance "$INSTANCE_ID_TO_RENT" \
            --image tensorflow/tensorflow:2.13.0-gpu \
            --disk 200 \
            --label "$LABEL" \
            --raw
        )"

        vast_use_instance_by_label "$LABEL";
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
    printf -v PROJECT_VENV_DIR_Q '/workspace/%q.venv' "$(project_name)";
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
        mkdir -p ${PROJECT_VENV_DIR_Q};
        cd ${PROJECT_GIT_DIR_Q};
        git init --bare;

        mkdir -p ${PROJECT_DIR_Q};
        cd ${PROJECT_DIR_Q};
        git init;
        git remote add origin ${PROJECT_GIT_DIR_Q};

        cd ${PROJECT_GIT_DIR_Q};
        echo '#!/bin/sh'                         > hooks/post-receive;
        printf \"cd %q\\n\" ${PROJECT_DIR_Q}    >> hooks/post-receive;
        echo 'unset GIT_DIR'                    >> hooks/post-receive;
        echo 'git fetch origin'                 >> hooks/post-receive;
        echo 'git checkout origin/main'         >> hooks/post-receive;
        chmod +x hooks/post-receive;
    ";
    git remote remove vast || true
    git remote add vast "${VAST_SSH_URL}${PROJECT_GIT_DIR_Q}"
    git push vast main
    ssh -o LogLevel=error "$VAST_SSH_URL" "
        set -euxo pipefail

        cd ${PROJECT_DIR_Q};
        python3.11 -m venv ${PROJECT_VENV_DIR_Q}
        source ${PROJECT_VENV_DIR_Q}/bin/activate

        if [ -f setup.py ]; then
            pip install .
        elif [ -f requirements.txt ]; then
            pip install -r requirements.txt
        fi
        pip install jupyter
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
        source ${PROJECT_DIR_Q}.venv/bin/activate;
        $CMD_Q
    "
    vast_venv_down
}

function vast_ssh {
    vast_venv_up
    if [[ "${VAST_INSTANCE_ID:-}" == "" ]]; then
        echo "No vast instance to run command in";
        return 1;
    fi

    printf -v PROJECT_DIR_Q '/workspace/%q' "$(project_name)";
    printf -v PROJECT_VENV_DIR_Q '/workspace/%q.venv' "$(project_name)";

    ssh -o LogLevel=error -t "$VAST_SSH_URL" "bash --init-file <(
        echo 'source \"\$HOME/.bashrc\";
        cd ${PROJECT_DIR_Q};
        source ${PROJECT_VENV_DIR_Q}/bin/activate';
    )"
}

function vast_remote_publish_jupyter_port {
    # Given a vast instance, and a sshable public server
    # expose jupyter on vast on the public server

    if [[ "$VAST_SSH_URL" == "" ]]; then
        # As a prereqisite for running this function, a VAST_SSH_URL must exist.
        # You can obtain one by running vast_ensure_instance or such.
        echo "No vast instance configured. Did you forget to run vast_ensure_instance?";
        return 1;
    fi


    # This should be something sshable. Examples include
    #  - An IP address like 123.45.67.89
    #  - An IP address with port like 123.45.67.89:2222
    #  - A URL like example.com
    #  - An IP address with user, like alice@123.45.67.89
    #  - A URL with user, like bob@example.com
    #  - An entry in your ~/.ssh/config
    PUBLIC_SSH_USERHOSTPORT="$1";
    PUBLIC_SSH_USERHOST="$(echo "$PUBLIC_SSH_USERHOSTPORT" | sed 's/:[0-9][0-9]*$//g')"
    PUBLIC_SSH_PORT="$(echo "$PUBLIC_SSH_USERHOSTPORT" | sed 's/^[^0-9]*\([0-9]*\)$/\1/g')"
    PUBLIC_SSH_PORT="${PUBLIC_SSH_PORT:-22}";

    # The public port to serve jupyter on
    SERVE_ON_PORT="$2";
    if [[ "$SERVE_ON_PORT" == "" ]]; then
        echo "Need a port to serve on. usage: vast_remote_publish_jupyter_port 9090 example.com 22"
        return 1;
    fi

    echo "Will route jupyter notebook through ssh tunnel on $PUBLIC_SSH_USERHOST:$PUBLIC_SSH_PORT and expose on port $SERVE_ON_PORT"

    printf -v PROJECT_DIR_Q '/workspace/%q' "$(project_name)";
    printf -v PROJECT_VENV_DIR_Q '/workspace/%q.venv' "$(project_name)";
    printf -v VAST_SSH_HOST_Q "%q" "$VAST_SSH_HOST"
    printf -v VAST_SSH_PORT_Q "%q" "$VAST_SSH_PORT"

    echo "Ensuring that ${PUBLIC_SSH_USERHOST} can reach ${VAST_SSH_HOST}";
    # Ensure that the public server can ssh into the vast server
    # First, grab the identity file from the public server
    PUBKEY="$(ssh -p "$PUBLIC_SSH_PORT" "$PUBLIC_SSH_USERHOST" 'cat "$HOME/.ssh/id_rsa.pub"')"
    # Check whether it's already authorized on vast
    if ! (ssh "$VAST_SSH_URL" 'cat "$HOME/.ssh/authorized_keys"' 2> /dev/null | grep --silent --fixed-strings "$PUBKEY"); then
        # If it's not already there, add it.
        echo "Adding pubkey of $PUBLIC_SSH_USERHOST to authorized_keys of $VAST_SSH_HOST";
        echo -e "\n$PUBKEY" | ssh "$VAST_SSH_URL" 'tee -a "$HOME/.ssh/authorized_keys"';
    else
        echo "Pubkey of $PUBLIC_SSH_USERHOST is already in authorized_keys of $VAST_SSH_HOST";
    fi

    JUPYTER_PORT="${JUPYTER_PORT:-9265}"
    if echo "$JUPYTER_PORT" | grep '[^0-9]'; then
        echo "JUPYTER_PORT of $JUPYTER_PORT is invalid. Setting to 9265.";
        JUPYTER_PORT="9265"
    fi
    if ssh "$VAST_SSH_URL" 'ps aux | grep jupyter | grep notebook' | grep --silent "$JUPYTER_PORT"; then
        echo "jupyter server already exists on port $JUPYTER_PORT"
        JUPYTER_URL="$(ssh "$VAST_SSH_URL" "cat /tmp/jupyter.url")";
    else
        echo "starting jupyter server on port $JUPYTER_PORT"
        ssh "$VAST_SSH_URL" "
            cd ${PROJECT_DIR_Q};
            source ${PROJECT_VENV_DIR_Q}/bin/activate;
            echo -n > /tmp/jupyter.url;
            echo 'Starting Jupyter server with command:';
            echo jupyter notebook --allow-root --no-browser --ip 0.0.0.0 --port ${JUPYTER_PORT};
            nohup jupyter notebook --allow-root --no-browser --ip 0.0.0.0 --port ${JUPYTER_PORT} > /tmp/jupyter.log 2> /tmp/jupyter.err < /dev/null &
            echo $! > /tmp/jupyter.pid;
            echo \"Started: pid=\$(cat /tmp/jupyter.pid)\";
            echo 'Waiting for jupyter to be ready';
            while [[ \"\$(cat /tmp/jupyter.url)\" == \"\" ]]; do
                grep  '^ *http://127.0.0.1:[0-9]*/tree?token=[a-f0-9]*$' /tmp/jupyter.err | sed 's/^ *//g' > /tmp/jupyter.url;
                sleep 0.2
                echo -n .
            done;
            echo;
        "
        JUPYTER_URL="$(ssh "$VAST_SSH_URL" "cat /tmp/jupyter.url")";
        echo "Internal jupyter url: $JUPYTER_URL";
    fi
    # If the port was taken, Jupyter will grab a new port. Make sure we take that into account
    JUPYTER_PORT="$(echo "$JUPYTER_URL" | sed 's/http:\/\/127.0.0.1:\([0-9]*\)\/tree.*$/\1/g')"
    printf -v VAST_KNOWN_KEY_Q "%q" "$(ssh-keyscan -p "$VAST_SSH_PORT" "$VAST_SSH_HOST" 2> /dev/null)";

    # Tunnel from this host to the vast instance
    # Note that this assumes that $SERVE_ON_PORT is publicly reachable on 
    ssh -p "$PUBLIC_SSH_PORT" "$PUBLIC_SSH_USERHOST" "
        echo $VAST_KNOWN_KEY_Q >> \"\$HOME/.ssh/known_hosts\";
        nohup ssh -N -p ${VAST_SSH_PORT_Q} root@${VAST_SSH_HOST_Q} -L ${JUPYTER_PORT}:localhost:${JUPYTER_PORT} &> /dev/null < /dev/null &
        nohup socat TCP-LISTEN:${SERVE_ON_PORT},reuseaddr,fork TCP:127.0.0.1:${JUPYTER_PORT} &> /dev/null < /dev/null &
    ";

    JUPYTER_PUBLIC_URL="$(echo "$JUPYTER_URL" | sed "s/127.0.0.1:$JUPYTER_PORT/$PUBLIC_SSH_USERHOST:$SERVE_ON_PORT/g")"
    echo "Your notebook is available at $JUPYTER_PUBLIC_URL";
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
