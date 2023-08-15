#!/bin/sh
set -eux

IMAGE_NAME="firecracker-rootfs:ubuntu-20.04"
CONTAINER_NAME="ubuntu"

docker build -t ${IMAGE_NAME} docker/
docker rm $CONTAINER_NAME || true
docker run --name $CONTAINER_NAME -h microvm $IMAGE_NAME

MOUNTDIR=/tmp/rootfs-docker
FS=rootfs.ext4.gold.rc
SIZE="7G"

# Create an ext4 filesystem and mount it in the host
rm $FS || true
qemu-img create -f raw $FS $SIZE
mkfs.ext4 $FS
mkdir -p $MOUNTDIR
sudo mount $FS $MOUNTDIR

# Copy the container file system into the mount dir
docker start $CONTAINER_NAME
sudo docker cp $CONTAINER_NAME:/ $MOUNTDIR
docker stop $CONTAINER_NAME
docker rm $CONTAINER_NAME

sudo umount $MOUNTDIR
