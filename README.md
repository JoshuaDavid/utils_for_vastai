# Overview

This directory contains helpers for specifically building and running Neuroscope on vast.ai instances. If you are not using vast.ai, you can ignore everything in here.

If you *are* using vast.ai, read on.

## Installation

1. Clone the repo
```sh
git clone https://github.com/JoshuaDavid/utils_for_vastai.git "$HOME/utils_for_vastai";
```
2. Source the util script in your `$HOME/.bashrc` or similar by adding the following line:
```sh
source "$HOME/utils_for_vastai/vast_utils.sh";
```

## Setting up an instance on vast.ai 

Run the following command in whatever repository you are working in (_not_ in the "$HOME/utils_for_vastai" repo):

```sh
vast_setup_auto_remote
```

This will set up an instance on `vast.ai`, clone the `main` branch of your current repository to a directory of the same name on that instance, and add a git remote named `vast` on your local machine. When you commit code, you can push it to `vast` (i.e. `git push vast main`), and the vast.ai instance will automatically update its code in the `/workspace/<your_project>` directory.

## Removing all instances from your account (THIS DELETES YOUR DATA)

This will ensure that you stop accumulating vast.ai charges. By making sure you don't have anything running or paused on vast.ai. You probably don't want to use this command.

```sh
vast_destroy_literally_all_the_instances_on_my_account_and_all_associated_data
```
