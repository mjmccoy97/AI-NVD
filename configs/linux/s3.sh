ip link add bond0 type bond mode 802.3ad
ip link set eth9 down
ip link set eth10 down
ip link set eth9 master bond0
ip link set eth10 master bond0
ip link set eth9 up
ip link set eth10 up
ip link set bond0 up

## Configure VLAN interface and IP address
ip link add link bond0 name bond0.100 type vlan id 100
ip addr add 172.16.10.3/24 dev bond0.100

## Bring up VLAN interface
ip link set bond0.100 up
