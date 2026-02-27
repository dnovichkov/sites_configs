#!/bin/bash
#
# deploy-remote.sh — Trigger deployment on remote server from local machine
#
# Usage:
#   ./deploy-remote.sh              Deploy all projects
#   ./deploy-remote.sh <project>    Deploy specific project
#   ./deploy-remote.sh --list       Show available projects
#
# Requires: SSH key added to ssh-agent (ssh-add ~/.ssh/your_key)
#

SERVER="91.188.212.141"
SERVER_USER="user"
DEPLOY_SCRIPT="/home/user/projects/sites_configs/deploy.sh"

# Forward SSH agent for git operations on server
ssh -t -A "${SERVER_USER}@${SERVER}" "bash ${DEPLOY_SCRIPT} ${*:-all}"
