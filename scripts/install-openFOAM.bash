#!/bin/bash

curl -s https://dl.openfoam.com/add-debian-repo.sh | sudo bash || exit 1

sudo apt-get -y install openfoam2206-default || exit 1

exit 0