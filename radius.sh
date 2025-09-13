#!/bin/bash
set -e


echo "=== Update & Upgrade ระบบ ==="
apt update -y && apt upgrade -y

echo "=== ติดตั้ง Service ที่ต้องใช้ ==="
apt install -y net-tools vim apache2 php mariadb-server mariadb-client freeradius-mysql freeradius

echo "=== เริ่มต้น MariaDB ==="
systemctl enable --now mariadb

echo "=== สร้าง Database และ User สำหรับ FreeRADIUS ==="
mysql -u root <<EOF
CREATE DATABASE IF NOT EXISTS radius_db;
CREATE USER IF NOT EXISTS 'radius_user'@'localhost' IDENTIFIED BY 'radius_pass123';
GRANT ALL PRIVILEGES ON radius_db.* TO 'radius_user'@'localhost';
FLUSH PRIVILEGES;
EOF

echo "=== Import Schema FreeRADIUS ==="
mysql -uradius_user -pradius_pass123 radius_db < /etc/freeradius/3.0/mods-config/sql/main/mysql/schema.sql

ln -sf /etc/freeradius/3.0/mods-available/sql /etc/freeradius/3.0/mods-enabled/sql

echo "=== แก้ไขไฟล์ mods-available/sql ==="
# ใช้ sed แก้ค่า server, port, login, password, radius_db และเอา comment ออก
chown freerad:freerad /etc/freeradius/3.0/mods-available/sql
cp sql /etc/freeradius/3.0/mods-available/sql


echo "=== เพิ่ม client ใน clients.conf โดยไม่เขียนทับเดิม ==="
# ตรวจสอบก่อนว่ามี client all อยู่หรือยัง
grep -q 'client all' /etc/freeradius/3.0/clients.conf || cat >> /etc/freeradius/3.0/clients.conf <<EOF

client all {
    ipaddr = 0.0.0.0/0
    secret = 12345
    nastype = other
}
EOF

#echo "=== Enable SQL Module ใน sites-enabled/default ==="
chown freerad:freerad /etc/freeradius/3.0/sites-available/default
chmod 640 /etc/freeradius/3.0/sites-available/default
cp default /etc/freeradius/3.0/sites-available/default

echo "=== สร้าง User got และกำหนดสิทธิ Bandwidth ==="
mysql -u radius_user -pradius_pass123 radius_db <<EOF
INSERT INTO radcheck (username, attribute, op, value) VALUES ('bncc', 'Cleartext-Password', ':=', '12345');
INSERT INTO radusergroup (username, groupname, priority) VALUES ('bncc', 'admin', 1);
INSERT INTO radgroupcheck (groupname, attribute, op, value) VALUES ('admin', 'Simultaneous-Use', ':=', '3');
INSERT INTO radgroupreply (groupname, attribute, op, value) VALUES ('admin', 'Mikrotik-Rate-Limit', ':=', '100M/100M');
INSERT INTO radgroupreply (groupname, attribute, op, value) VALUES ('admin', 'WISPr-Bandwidth-Max-Down', ':=', '100000000');
INSERT INTO radgroupreply (groupname, attribute, op, value) VALUES ('admin', 'WISPr-Bandwidth-Max-Up', ':=', '100000000');
INSERT INTO radgroupreply (groupname, attribute, op, value) VALUES ('admin', 'Idle-Timeout', ':=', '900');
INSERT INTO radgroupreply (groupname, attribute, op, value) VALUES ('admin', 'Session-Timeout', ':=', '14400');
EOF


echo "=== ตั้งค่าสิทธิ์ไฟล์และโฟลเดอร์ ==="
chown -R freerad:freerad /etc/freeradius/3.0
chmod -R 640 /etc/freeradius/3.0/*
find /etc/freeradius/3.0 -type d -exec chmod 750 {} \;

chown -R mysql:mysql /var/lib/mysql
chmod 750 /var/lib/mysql

echo "=== Restart Services ==="
systemctl enable --now freeradius
systemctl restart freeradius
systemctl enable --now apache2

apt install phpmyadmin php-mysql -y
systemctl restart apache2

echo "=== อนุญาต Firewall port ที่จำเป็น ==="
ufw allow 1812/udp
ufw allow 1813/udp
ufw allow 80/tcp
ufw allow 3306/tcp
ufw allow 22/tcp
ufw reload

echo "=== เสร็จสิ้น! FreeRADIUS พร้อมใช้งานผ่าน DB แล้ว ==="
