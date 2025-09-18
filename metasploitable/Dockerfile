# Utilisation de Debian comme image de base
FROM debian:latest

# Suppression des variables d'environnement réseau qui ne sont plus nécessaires
# ENV NETWORK_NAME="meta_network"
# ENV CONTAINER_NAME="metasploitable"
# ENV CONTAINER_IP="192.168.1.100"

# Mise à jour et installation des paquets nécessaires
RUN apt-get update && apt-get install -y \
    netcat-openbsd \
    apache2 \
    vsftpd \
    telnetd \
    samba \
    mariadb-server \
    openssh-server \
    postfix \
    iputils-ping \
    net-tools \
    iproute2 \
    iptables \
    && apt-get clean

# Configuration de SSH
RUN mkdir /var/run/sshd && \
    echo 'root:toor' | chpasswd

# Configuration de Apache
RUN echo "<h1>Bienvenue sur Metasploitable</h1>" > /var/www/html/index.html

# Configuration de MariaDB
RUN service mariadb start || service mysql start && \
    mysqld_safe & \
    sleep 5 && \
    mysql -e "CREATE DATABASE metasploit;" && \
    mysql -e "CREATE USER 'metasploit'@'localhost' IDENTIFIED BY 'password';" && \
    mysql -e "GRANT ALL PRIVILEGES ON metasploit.* TO 'metasploit'@'localhost';" && \
    mysql -e "FLUSH PRIVILEGES;"

# Configuration de Samba
RUN echo -e "[public]\npath = /srv/samba\nwritable = yes\nguest ok = yes\n" >> /etc/samba/smb.conf && \
    mkdir -p /srv/samba && \
    useradd -m samba_user && \
    (echo "password"; echo "password") | smbpasswd -s -a samba_user && \
    smbpasswd -e samba_user

# Création d'un script de démarrage des services
RUN echo '#!/bin/bash\n\
service ssh start\n\
service apache2 start\n\
service vsftpd start\n\
service telnet start\n\
service smbd start\n\
service postfix start\n\
service mariadb start\n\
tail -f /dev/null' > /start-services.sh && \
chmod +x /start-services.sh

# Commande par défaut
CMD ["/start-services.sh"]

# Exposer les ports nécessaires
EXPOSE 21 22 23 25 80 139 443 3306 5432 8000
