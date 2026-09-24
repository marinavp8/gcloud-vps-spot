# WordPress en VM Spot de GCP (Iowa)

Terraform crea la infraestructura en Google Cloud y Ansible instala WordPress con nginx, PHP-FPM, MariaDB y un certificado de Let's Encrypt.
El sitio se publica en un dominio de sslip.io con el formato `wp-<ip-con-guiones>.sslip.io`.

**Despliegue actual:** https://wp-136-115-4-48.sslip.io (IP `136.115.4.48`)

## Qué se crea

| Recurso | Nombre | Detalle |
|---|---|---|
| VM Spot | `wp-spot` | `e2-custom-4-8192` (4 vCPU, 8 GB), Ubuntu 24.04, disco de arranque de 20 GB. Si Google la expulsa, se detiene (`STOP`) en vez de borrarse. |
| Disco de datos | `wp-spot-data` | 40 GB `pd-balanced`. Es un recurso independiente conectado con `google_compute_attached_disk`, así que sobrevive si se recrea la VM. |
| IP estática | `wp-spot-ip` | IP pública regional (`us-central1`). |
| Firewall | `wp-spot-web`, `wp-spot-ssh` | Abre 80/443 a todo el mundo y 22 a `ssh_source_ranges` (por defecto `0.0.0.0/0`). |
| Claves SSH | `keys/wp-spot`, `keys/wp-spot.pub` | Pareja ED25519 generada por Terraform (`tls_private_key`). La pública se inyecta en la VM para el usuario `ubuntu`. |
| Inventario Ansible | `ansible/inventory.ini` | Lo genera Terraform con la IP, la clave y el dominio. |

Proyecto `codecrypto-ai`, región `us-central1`, zona `us-central1-a`.

## Estructura

```
.
├── terraform/
│   ├── versions.tf      # providers: google, tls, local
│   ├── variables.tf     # proyecto, zona, tipo de máquina, tamaño de disco…
│   ├── main.tf          # claves, IP, disco, firewall, VM, inventario
│   └── outputs.tf       # ip, wp_url, comando ssh
├── ansible/
│   ├── ansible.cfg
│   ├── site.yml         # playbook
│   └── templates/
│       ├── wp-config.php.j2
│       └── nginx-wordpress.conf.j2
└── keys/                # claves SSH (no versionar)
```

## Qué hace el playbook (`ansible/site.yml`)

1. **Disco de datos:** espera a `/dev/disk/by-id/google-data`, lo formatea en ext4 si no tiene sistema de ficheros y lo monta en `/data` (con `nofail`).
2. **Bind mounts:** monta `/data/mysql` en `/var/lib/mysql` y `/data/www` en `/var/www`, de modo que la BD y WordPress viven en el disco de 40 GB.
3. **Paquetes:** instala nginx, MariaDB, certbot y PHP 8.3-FPM con sus extensiones (mysql, curl, gd, intl, mbstring, xml, zip, imagick).
4. **Base de datos:** crea la BD `wordpress` y el usuario `wordpress`. La contraseña se genera en local y se guarda en `ansible/.wp-secrets/db_pass`.
5. **WordPress:** descarga la última versión en `/var/www/wordpress` y genera `wp-config.php` con salts de la API oficial. El fichero no se sobrescribe en re-ejecuciones.
6. **PHP:** sube los límites a 64 MB por subida y 256 MB de memoria.
7. **nginx y Let's Encrypt:** el vhost se genera desde `templates/nginx-wordpress.conf.j2` con la variable `wp_tls`.
   - Primero se despliega solo con HTTP y la ruta `/.well-known/acme-challenge/` servida desde `/var/www/letsencrypt`.
   - `certbot certonly --webroot` pide el certificado para `wp-<ip>.sslip.io`. Es idempotente gracias a `creates:`.
   - Después se regenera el vhost con TLS: el puerto 80 redirige con 301 a HTTPS (salvo el desafío ACME) y el 443 sirve WordPress con TLS 1.2/1.3, HTTP/2 y HSTS.
   - La renovación queda automática con `certbot.timer` y un `--deploy-hook` que recarga nginx.
   - Se usa `webroot` en vez de `certbot --nginx` para que Ansible siga siendo el dueño del vhost y re-ejecutar el playbook no rompa el SSL.
   - La variable opcional `letsencrypt_email` permite registrar un email. Si está vacía, se usa `--register-unsafely-without-email`.
   - También bloquea `xmlrpc.php` y los ficheros ocultos, y cachea los estáticos 30 días.

## Requisitos

- Terraform ≥ 1.5, gcloud autenticado y Ansible ≥ 2.15.
- La VM trae nginx 1.24 (Ubuntu 24.04), que no admite la directiva `http2 on;`. Por eso se usa `listen 443 ssl http2`.
- Colecciones de Ansible: `community.general`, `community.mysql`, `ansible.posix`.
  ```bash
  ansible-galaxy collection install community.general community.mysql ansible.posix
  ```

## Uso

```bash
# 1. Infraestructura
cd terraform
terraform init
GOOGLE_OAUTH_ACCESS_TOKEN=$(gcloud auth print-access-token) terraform apply

# 2. Instalar WordPress
cd ../ansible
ansible-playbook site.yml </dev/null

# 3. Acceso
terraform -chdir=../terraform output
ssh -i keys/wp-spot ubuntu@<ip>      # desde la raíz del proyecto
```

Notas:
- **Credenciales:** no hay ADC (Application Default Credentials) configuradas, así que el provider usa el token de la cuenta activa de gcloud a través de `GOOGLE_OAUTH_ACCESS_TOKEN`. Otra opción es ejecutar `gcloud auth application-default login` una vez.
- **`</dev/null`:** hace falta en el terminal Warp. Sin él, Ansible falla con *"Non-blocking file handles detected"*.
- **Re-ejecución:** el playbook es idempotente y se puede lanzar varias veces.

## Verificación realizada

```bash
dig +short wp-136-115-4-48.sslip.io         # → 136.115.4.48
curl -I http://wp-136-115-4-48.sslip.io/    # → 301 a https://
curl -I https://wp-136-115-4-48.sslip.io/   # → 302 a /wp-admin/install.php (cert válido, HTTP/2)
sudo certbot renew --dry-run               # → success (en la VM)
echo | openssl s_client -connect wp-136-115-4-48.sslip.io:443 -servername wp-136-115-4-48.sslip.io \
  | openssl x509 -noout -issuer -dates      # → Let's Encrypt, válido hasta el 23-dic-2026
```

Dentro de la VM se comprobó lo siguiente: 4 CPUs, 8 GB de RAM, `/dev/sdb` de 40 GB montado en `/data`, `/var/www` y `/var/lib/mysql` montados desde el disco de datos, y `provisioningModel = SPOT`.

## Pendiente / siguientes pasos

- **Completar la instalación de WordPress** en `/wp-admin/install.php` (título, admin y contraseña). Mientras no se haga, cualquiera puede completarla.
- **Cambio de IP:** si cambia la IP, cambia el dominio. Hay que regenerar el inventario (`terraform apply`) y re-ejecutar el playbook, que pedirá un certificado nuevo.
- **SSH:** restringir el acceso con `-var 'ssh_source_ranges=["<tu-ip>/32"]'`.
- **Spot:** GCP puede parar la VM en cualquier momento. Para arrancarla de nuevo:
  `gcloud compute instances start wp-spot --zone us-central1-a`.
  Los datos se conservan en el disco `wp-spot-data` y la IP es estática.

## Destruir

```bash
cd terraform
GOOGLE_OAUTH_ACCESS_TOKEN=$(gcloud auth print-access-token) terraform destroy
```

⚠️ `destroy` elimina también el disco de datos. Para conservarlo, sácalo antes del estado:
`terraform state rm google_compute_disk.data google_compute_attached_disk.data`.

## Ficheros sensibles (en `.gitignore`)

`keys/`, `terraform/*.tfstate*` (contienen la clave privada), `ansible/inventory.ini` y `ansible/.wp-secrets/`.
