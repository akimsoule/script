# Lancer le conteneur avec les paramètres spécifiés
sudo docker run --rm -it --shm-size=512m -p 6901:6901 --user root -e VNC_PW=password kasmweb/core-kali-rolling:1.16.0

# Changer le mot de passe de l'utilisateur root
echo "root:root" | chpasswd
