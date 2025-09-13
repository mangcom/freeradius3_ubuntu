#!/bin/bash
set -euo pipefail

# ฟังก์ชันหน่วงเวลาและแสดงสถานะ
pause() { sleep 2; }

echo "=== ตั้งค่าพารามิเตอร์ผ่านคีย์บอร์ด ==="
read -rp "Database name [radius_db]: " DB_NAME
DB_NAME=${DB_NAME:-radius_db}

read -rp "Database user [radius_user]: " DB_USER
DB_USER=${DB_USER:-radius_user}

read -rp "Database password [radius_pass123]: " DB_PASS
DB_PASS=${DB_PASS:-radius_pass123}

read -rp "RADIUS admin username (radcheck) [bncc]: " ADMIN_USER
ADMIN_USER=${ADMIN_USER:-bncc}

read -rp "RADIUS admin password (radcheck) [12345]: " ADMIN_PASS
ADMIN_PASS=${ADMIN_PASS:-12345}

read -rp "RADIUS secret (สำหรับ client all) [12345]: " RADIUS_SECRET
RADIUS_SECRET=${RADIUS_SECRET:-12345}

echo
echo "สรุปค่าที่จะใช้:"
echo "  DB_NAME   = $DB_NAME"
echo "  DB_USER   = $DB_USER"
echo "  DB_PASS   = ********"
echo "  ADMIN_USER  = $ADMIN_USER"
echo "  ADMIN_PASS  = ********"
echo "  RADIUS_SECRET = ********"
read -rp "ยืนยันหรือไม่? [Y/n]: " CONFIRM
CONFIRM=${CONFIRM:-Y}
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
  echo "ยกเลิกการทำงาน"; exit 1
fi
pause

export DEBIAN_FRONTEND=noninteractive

echo "=== Update & Upgrade ระบบ ==="
pause
apt update -y && apt upgrade -y

echo "=== ติดตั้ง Service ที่ต้องใช้ ==="
pause
apt install -y net-tools vim apache2 php php-mysql mariadb-server mariadb-client freeradius freeradius-mysql ufw

echo "=== เริ่มต้น MariaDB ==="
pause
systemctl enable --now mariadb

echo "=== สร้าง Database และ User สำหรับ FreeRADIUS ==="
pause
mysql -u root <<EOF
CREATE DATABASE IF NOT EXISTS \`$DB_NAME\`;
CREATE USER IF NOT EXISTS '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASS';
GRANT ALL PRIVILEGES ON \`$DB_NAME\`.* TO '$DB_USER'@'localhost';
FLUSH PRIVILEGES;
EOF

echo "=== Import Schema FreeRADIUS ==="
pause
SCHEMA_FILE="/etc/freeradius/3.0/mods-config/sql/main/mysql/schema.sql"
if [[ ! -f "$SCHEMA_FILE" ]]; then
  echo "[ERROR] ไม่พบไฟล์ Schema: $SCHEMA_FILE"; exit 1
fi
mysql -u"$DB_USER" -p"$DB_PASS" "$DB_NAME" < "$SCHEMA_FILE"

echo "=== เปิดใช้โมดูล SQL (symlink ไปยัง mods-enabled) ==="
pause
ln -sf /etc/freeradius/3.0/mods-available/sql /etc/freeradius/3.0/mods-enabled/sql

echo "=== แก้ค่าเชื่อมต่อ DB ใน /etc/freeradius/3.0/mods-available/sql ==="
pause
SQL_MOD_FILE="/etc/freeradius/3.0/mods-available/sql"
sed -ri 's|^\s*dialect\s*=.*$|dialect = "mysql"|' "$SQL_MOD_FILE"
sed -ri 's|^\s*server\s*=.*$|server = "localhost"|' "$SQL_MOD_FILE"
sed -ri 's|^\s*port\s*=.*$|port = 3306|' "$SQL_MOD_FILE"
sed -ri "s|^\s*login\s*=.*$|login = \"$DB_USER\"|" "$SQL_MOD_FILE"
sed -ri "s|^\s*password\s*=.*$|password = \"$DB_PASS\"|" "$SQL_MOD_FILE"
sed -ri "s|^\s*radius_db\s*=.*$|radius_db = \"$DB_NAME\"|" "$SQL_MOD_FILE"
# เปิด read_clients = yes ถ้าคอมเมนต์ไว้
if grep -q '^\s*#\s*read_clients\s*=\s*yes' "$SQL_MOD_FILE"; then
  sed -ri 's|^\s*#\s*read_clients\s*=\s*yes|read_clients = yes|' "$SQL_MOD_FILE"
fi
chown freerad:freerad "$SQL_MOD_FILE"
chmod 640 "$SQL_MOD_FILE"

echo "=== เปิดใช้ SQL ใน sites-available/default และ inner-tunnel ==="
pause
for SITE in /etc/freeradius/3.0/sites-available/{default,inner-tunnel}; do
  [ -f "$SITE" ] || continue
  sudo chown freerad:freerad "$SITE"
  sudo chmod 640 "$SITE"

  for section in authorize accounting session post-auth; do
    # ถ้ายังไม่มี 'sql' ภายในบล็อกของ section นั้น ให้แทรกเพิ่มหลังบรรทัดเปิด {
    if ! awk "/^${section}[[:space:]]*\\{/,/^\\}/ { if (\$1 == \"sql\") found=1 } END { exit !found }" "$SITE"; then
      sudo sed -E -i "/^${section}[[:space:]]*\\{/{n; i\\        sql
}" "$SITE"
    fi
  done
done

ln -sf /etc/freeradius/3.0/mods-available/sql /etc/freeradius/3.0/mods-enabled/sql

echo "=== เพิ่ม/อัปเดต client all ใน clients.conf ด้วย RADIUS secret ที่กำหนด ==="
pause
CLIENTS_CONF="/etc/freeradius/3.0/clients.conf"
if ! grep -q 'client all' "$CLIENTS_CONF"; then
  # เพิ่มบล็อกใหม่โดยฝัง secret ที่ผู้ใช้กรอก
  cat >> "$CLIENTS_CONF" <<EOF

client all {
    ipaddr = 0.0.0.0/0
    secret = $RADIUS_SECRET
    nastype = other
}
EOF
else
  # อัปเดตเฉพาะบรรทัด secret ภายในบล็อก client all ที่มีอยู่แล้ว
  sed -ri "/client all\s*\{/,/}/ s|^\s*secret\s*=.*$|    secret = $RADIUS_SECRET|" "$CLIENTS_CONF"
fi

echo "=== เพิ่มผู้ใช้ ADMIN และกำหนดสิทธิ Bandwidth ==="
pause
mysql -u"$DB_USER" -p"$DB_PASS" "$DB_NAME" <<EOF
INSERT INTO radcheck (username, attribute, op, value)
VALUES ('$ADMIN_USER', 'Cleartext-Password', ':=', '$ADMIN_PASS')
ON DUPLICATE KEY UPDATE value = VALUES(value);

INSERT INTO radusergroup (username, groupname, priority)
VALUES ('$ADMIN_USER', 'admin', 1)
ON DUPLICATE KEY UPDATE groupname = VALUES(groupname), priority = VALUES(priority);

INSERT INTO radgroupcheck (groupname, attribute, op, value)
VALUES ('admin', 'Simultaneous-Use', ':=', '3')
ON DUPLICATE KEY UPDATE value = VALUES(value);

INSERT INTO radgroupreply (groupname, attribute, op, value) VALUES
('admin', 'Mikrotik-Rate-Limit', ':=', '100M/100M')
ON DUPLICATE KEY UPDATE value = VALUES(value);

INSERT INTO radgroupreply (groupname, attribute, op, value) VALUES
('admin', 'WISPr-Bandwidth-Max-Down', ':=', '100000000')
ON DUPLICATE KEY UPDATE value = VALUES(value);

INSERT INTO radgroupreply (groupname, attribute, op, value) VALUES
('admin', 'WISPr-Bandwidth-Max-Up', ':=', '100000000')
ON DUPLICATE KEY UPDATE value = VALUES(value);

INSERT INTO radgroupreply (groupname, attribute, op, value) VALUES
('admin', 'Idle-Timeout', ':=', '900')
ON DUPLICATE KEY UPDATE value = VALUES(value);

INSERT INTO radgroupreply (groupname, attribute, op, value) VALUES
('admin', 'Session-Timeout', ':=', '14400')
ON DUPLICATE KEY UPDATE value = VALUES(value);
EOF

echo "=== ตั้งค่าสิทธิ์ไฟล์และโฟลเดอร์ ==="
pause
chown -R freerad:freerad /etc/freeradius/3.0
chmod -R 640 /etc/freeradius/3.0/* || true
find /etc/freeradius/3.0 -type d -exec chmod 750 {} \;

chown -R mysql:mysql /var/lib/mysql
chmod 750 /var/lib/mysql

echo "=== ติดตั้ง phpMyAdmin และรีสตาร์ต Apache ==="
pause
apt install -y phpmyadmin php-mysql || true
pause
systemctl enable --now apache2
systemctl restart apache2
pause

echo "=== อนุญาต Firewall port ที่จำเป็น ==="
pause
ufw allow 1812/udp || true
ufw allow 1813/udp || true
ufw allow 80/tcp   || true
ufw allow 3306/tcp || true
ufw allow 22/tcp   || true
ufw reload         || true
pause

echo "=== Restart & Enable FreeRADIUS ==="
pause
systemctl enable --now freeradius
systemctl restart freeradius

pause
radtest "$ADMIN_USER" "$ADMIN_PASS" 127.0.0.1 0 "$RADIUS_SECRET"
pause

echo "=== เสร็จสิ้น! FreeRADIUS พร้อมใช้งานผ่าน MariaDB แล้ว ==="
echo "    - DB: name=$DB_NAME user=$DB_USER"
echo "    - Admin user ใน radcheck: $ADMIN_USER"
echo "    - RADIUS secret (client all): ตั้งค่าแล้ว (โปรดพิจารณาจำกัด ipaddr ให้แคบลงเพื่อความปลอดภัย)"
