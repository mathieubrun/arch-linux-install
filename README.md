# Arch linux installation script

Installation script targeted for a developper laptop.

## Features

- luks encryption for system and swap partitions
- btrfs raid1 for 2 ssd drives
- optimus-manager for hybrid graphics

## Usage

1. Boot on Arch linux installation media
2. Setup internet connexion
3. Install git
4. 

```` sh
git clone https://github.com/mathieubrun/arch-linux-install
export DMCRYPT_PASSWORD=your_password
export VBOX=0
./install.sh
````

## Tested on 

- Lenovo x1 extreme gen2

## Testing with packer

```` sh
packer build -force arch_template.json
````


