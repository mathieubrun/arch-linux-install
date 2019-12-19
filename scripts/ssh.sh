#!/usr/bin/env bash

echo 'root:root' | chpasswd
systemctl start sshd.service