source ~/devstack/asl-openrc
unset OS_USER_DOMAIN_ID OS_PROJECT_DOMAIN_ID
export OS_USER_DOMAIN_NAME=Default OS_PROJECT_DOMAIN_NAME=Default
export KUBECONFIG=$HOME/td2/ansible/tunnel.kubeconfig
