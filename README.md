# Firecracker Playground

## First contact

- Preliminaries

```bash
lsmod | grep kvm
sudo setfacl -m u:${USER}:rw /dev/kvm
```

- Download and Install

```bash
wget https://github.com/firecracker-microvm/firecracker/releases/download/v1.4.1/firecracker-v1.4.1-x86_64.tgz
```

- Get it running

```bash
export API_SOCKET="/tmp/firecracker.socket"
rm $API_SOCKET || true
./firecracker-v1.4.1-x86_64 --api-sock "${API_SOCKET}"
```

- Keep that in foreground and open up another shell
- Download image fs, id_rsa (for ssh access) and kernel from: <https://s3.amazonaws.com/spec.ccfc.min>

```bash
mkdir -p vms/ubuntu-22.04/ && cd vms/ubuntu-22.04/
wget https://s3.amazonaws.com/spec.ccfc.min/cci-artifacts-20230601/x86_64/ubuntu-22.04.ext4
wget https://s3.amazonaws.com/spec.ccfc.min/cci-artifacts-20230601/x86_64/ubuntu-22.04.id_rsa
wget https://s3.amazonaws.com/spec.ccfc.min/ci-artifacts-20230601/x86_64/vmlinux-5.10.181
```

- Setup virtual network interface tap0

```
TAP_DEV="tap0"
TAP_IP="172.16.0.1"
MASK_SHORT="/30"

sudo ip link del "$TAP_DEV" 2> /dev/null || true
sudo ip tuntap add dev "$TAP_DEV" mode tap
sudo ip addr add "${TAP_IP}${MASK_SHORT}" dev "$TAP_DEV"
sudo ip link set dev "$TAP_DEV" up
```

- Result:

```bash
❯ ip addr
[...]
4: docker0: <NO-CARRIER,BROADCAST,MULTICAST,UP> mtu 1500 qdisc noqueue state DOWN group default
    link/ether 02:42:7a:53:06:0f brd ff:ff:ff:ff:ff:ff
    inet 172.17.0.1/16 brd 172.17.255.255 scope global docker0
       valid_lft forever preferred_lft forever
8: tap0: <NO-CARRIER,BROADCAST,MULTICAST,UP> mtu 1500 qdisc fq_codel state DOWN group default qlen 1000
    link/ether c6:96:0d:f0:2d:89 brd ff:ff:ff:ff:ff:ff
    inet 172.16.0.1/30 scope global tap0
       valid_lft forever preferred_lft forever
```

- Setup the microvm internet access, and enable IP forwarding if you don't (guide)

```bash
# Enable ip forwarding (just in case)
sudo sh -c "echo 1 > /proc/sys/net/ipv4/ip_forward"

# Set your network interface for routing

export IF_FWD=wlp2s0

# Set up microVM internet access (delete first in case they exist)

sudo iptables -t nat -D POSTROUTING -o ${IF_FWD} -j MASQUERADE || true
sudo iptables -D FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT || true
sudo iptables -D FORWARD -i tap0 -o ${IF_FWD} -j ACCEPT || true

sudo iptables -t nat -A POSTROUTING -o ${IF_FWD} -j MASQUERADE
sudo iptables -I FORWARD 1 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
sudo iptables -I FORWARD 1 -i tap0 -o ${IF_FWD} -j ACCEPT
```

- Setup logs:

```bash
API_SOCKET="/tmp/firecracker.socket"
LOGFILE="/tmp/firecracker.log"
touch $LOGFILE

# Set log file
curl -X PUT --unix-socket "${API_SOCKET}" \
    --data "{
        \"log_path\": \"${LOGFILE}\",
        \"level\": \"Debug\",
        \"show_level\": true,
        \"show_log_origin\": true
    }" \
    "http://localhost/logger"
```

Configure the machine settings

```bash
ROOTFS="$PWD/vms/ubuntu-22.04/ubuntu-22.04.ext4"
KERNEL="$PWD/vms/ubuntu-22.04/vmlinux-5.10.181.bin" # Use the full path!
KERNEL_BOOT_ARGS="console=ttyS0 reboot=k panic=1 pci=off"
FC_MAC="06:00:AC:10:00:02" # can this be arbitrary???
```

Run it, specifying the kernel, rootfs, network config and finally starting up the instance:

```bash
curl -X PUT --unix-socket "${API_SOCKET}" \
    --data "{
        \"kernel_image_path\": \"${KERNEL}\",
        \"boot_args\": \"${KERNEL_BOOT_ARGS}\"
    }" \
    "http://localhost/boot-source"

curl -X PUT --unix-socket "${API_SOCKET}" \
    --data "{
        \"drive_id\": \"rootfs\",
        \"path_on_host\": \"${ROOTFS}\",
        \"is_root_device\": true,
        \"is_read_only\": false
    }" \
    "http://localhost/drives/rootfs"

curl -X PUT --unix-socket "${API_SOCKET}" \
    --data "{
        \"iface_id\": \"net1\",
        \"guest_mac\": \"$FC_MAC\",
        \"host_dev_name\": \"$TAP_DEV\"
    }" \
    "http://localhost/network-interfaces/net1"

curl -X PUT --unix-socket "${API_SOCKET}" \
    --data "{
        \"action_type\": \"InstanceStart\"
    }" \
    "http://localhost/actions"
```

After that, go to the terminal you launched firecracker and there you are!
Also, you can access via ssh:

```bash
chmod 400 vms/ubuntu-22.04/ubuntu-22.04.id_rsa
ssh -i vms/ubuntu-22.04/ubuntu-22.04.id_rsa root@172.16.0.2
```

Now, inside the machine, add the route in order to forward traffic to the host:

```bash
ip route add default via 172.16.0.1 dev eth0
```

In order to terminate the machine, you have to `reboot` it. Don't use `halt`!

## Some useful API endpoints

Swagger:

- <https://raw.githubusercontent.com/firecracker-microvm/firecracker/main/src/api_server/swagger/firecracker.yaml>

You can get the info about the vm that it's running:

```bash
curl --unix-socket /tmp/firecracker.socket -X GET "http://localhost/vm/config" > vms/ubuntu-22.04/vmconfig.json
```

With that JSON you will be able to start the microvm much more easily...

## Run foreground with the JSON config file

Instead of using the API, lets reuse the config.json file and take the opportunity to tweak it a bit:

- Increasing vCPU and Mem
- Configure the IP forwarding via boot parameters

Then:

```bash
export API_SOCKET="/tmp/firecracker.socket"
rm $API_SOCKET

cd vms/ubuntu-22.04
firecracker --api-sock $API_SOCKET --config-file vmconfig.json
```

This file could be easily templatized and generated on the fly.

## Restore a clean rootfs after every restart

We keep a copy of our golden image at `ubuntu-22.04.ext4.gold`  and, every time we want to run a new vm, we copy it and resize it to the desired size:

```bash
cp ubuntu-22.04.ext4.gold ubuntu-22.04.ext4
e2fsck -f ubuntu-22.04.ext4 -y
resize2fs ubuntu-22.04.ext4 10G
```

This is quite fast with this small rootfs, but if our firecracker golden image is too heavy, the start up time may increase significantly (needs more testing).

## Create a custom rootfs which runs Dockerd on start up

Working prototype at `vms/dockerd-ubuntu`

- The shell script builds a Docker image which is the baseline for our rootfs.
- The vmsconfig.json uses the same kernel as with the previous image, since it seems it has the required modules for running Docker

## TODO

- The rootfs should be copied every time we want to use it but, other idea could be to configure the rootfs as read-only.
- Configure systemd so in startup we can have Dockerd and autoregister a GitHub Self-Hosted Runner

## References

- <https://github.com/firecracker-microvm/firecracker/blob/main/docs/getting-started.md>
- <https://github.com/firecracker-microvm/firecracker/blob/fea3897ccfab0387ce5cd4fa2dd49d869729d612/docs/getting-started.md#running-firecracker>
- <https://jvns.ca/blog/2021/01/23/firecracker--start-a-vm-in-less-than-a-second/>
- <https://github.com/firecracker-microvm/firectl>
- <https://leo.leung.xyz/wiki/Firecracker>
- The next one is good summary: <https://betterprogramming.pub/getting-started-with-firecracker-a88495d656d9>
- Adding an external disk: <https://www.palomargc.com/posts/Firecracker-microMV/>
- Pretty complete reference in order to build a microvm with docker inside: <https://www.felipecruz.es/exploring-firecracker-microvms-for-multi-tenant-dagger-ci-cd-pipelines/>
  - > I learned that the default kernel configurations of Firecracker microVMs do not come prepared for running containers. You must customize the Linux kernel by compiling some specific modules on it.
- <https://hocus.dev/blog/qemu-vs-firecracker/>
