# shellcheck shell=bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0
# Node.js 22 with TypeScript, tsx, pnpm and yarn
dnf install -y nodejs22 nodejs22-npm
if ! command -v node >/dev/null && [[ -x /usr/bin/node-22 ]]; then ln -sf /usr/bin/node-22 /usr/local/bin/node; fi
npm install -g --no-fund --no-audit typescript tsx pnpm yarn
