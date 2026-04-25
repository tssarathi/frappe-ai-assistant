FROM docker.io/vyogo/erpnext:sne-develop

USER root
# curl is already present in the CentOS Stream 9 base image; no extra install needed.
COPY bootstrap.sh /usr/local/bin/bootstrap.sh
RUN chmod +x /usr/local/bin/bootstrap.sh

# Stay as root so the entrypoint can chown the named-volume mountpoint
# (frontend/node_modules) which Docker creates as root by default. The
# script self-drops to the frappe user after the fix-up — see the
# `id -u = 0` block at the top of bootstrap.sh.
WORKDIR /home/frappe/frappe-bench
ENTRYPOINT ["/usr/local/bin/bootstrap.sh"]
