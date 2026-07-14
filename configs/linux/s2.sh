## Configure backend (rail) links to stripe1 leaf switches (e1-4 side)
for i in 1 2 3 4 5 6 7 8; do
  ip link set eth$i up
  ip link add link eth$i name eth$i.100 type vlan id 100
  ip link set eth$i.100 up
  echo 2 > /proc/sys/net/ipv6/conf/eth$i.100/accept_ra
  ip -6 addr add fd00:100:$i:1:0:4:0:2/96 dev eth$i.100

  # Pin this rail's source address to its own routing table so a reply/request
  # sourced from rail $i can never egress a different rail's interface (the
  # kernel doesn't otherwise honor -I when multiple equal-metric default
  # routes exist across interfaces).
  table=$((100 + i))
  src_ip="fd00:100:$i:1:0:4:0:2"
  gw=""
  for attempt in $(seq 1 15); do
    gw=$(ip -6 route show dev eth$i.100 proto ra | awk '/^default/ {print $3}')
    [ -n "$gw" ] && break
    sleep 1
  done
  ip -6 rule add priority $((200 + i)) from $src_ip table $table
  ip -6 route add default via $gw dev eth$i.100 table $table
done

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
ip addr add 172.16.10.2/24 dev bond0.100

## Bring up VLAN interface
ip link set bond0.100 up
