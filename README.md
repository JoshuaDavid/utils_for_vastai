# Overview

This directory contains helpers for specifically building and running Neuroscope on vast.ai instances. If you are not using vast.ai, you can ignore everything in here.

If you *are* using vast.ai, read on.

## Setting up your local environment

You will need to `source vastai/vast_utils.sh` within your `~/.bashrc` or equivalent to gain access to helper functions. After adding this, you will either need to restart your shell, or run the command

```sh
source vastai/vast_utils.sh
```

within your current shell.

## Setting up an instance on vast.ai 

Run the following command:

```sh
vast_setup_auto_remote
```

This will set up an instance on `vast.ai`, clone the `main` branch of your current repository to a directory of the same name on that instance, and add a git remote named `vast` on your local machine. When you commit code, you can push it to `vast` (i.e. `git push vast main`), and the vast.ai instance will automatically update its code in the `/workspace/<your_project>` directory.

## Removing all instances from your account (THIS DELETES YOUR DATA)

This will ensure that you stop accumulating vast.ai charges. By making sure you don't have anything running or paused on vast.ai. You probably don't want to use this command.

```sh
vast_destroy_literally_all_the_instances_on_my_account_and_all_associated_data
```
