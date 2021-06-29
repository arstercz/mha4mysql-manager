# masterha_master_switch --master_state=dead  --global_conf=/etc/masterha/default.cnf --conf=/etc/masterha/app_3306.cnf --dead_master_host=10.1.1.25 --dead_master_ip=10.1.1.25 --dead_master_port=3306
# masterha_master_switch --master_state=alive --global_conf=/etc/masterha/default.cnf --conf=/etc/masterha/app_3306.cnf
# masterha_master_switch --master_state=alive --global_conf=/etc/masterha/default.cnf --conf=/etc/masterha/app_3306.conf --orig_master_is_new_slave
# masterha_check_repl --global_conf=/etc/masterha/default.cnf --conf=/etc/masterha/app_3306.cnf
