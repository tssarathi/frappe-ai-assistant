FROM docker.io/vyogo/erpnext:sne-version-15

USER root
# curl is already present in the CentOS Stream 9 base image; no extra install needed.
COPY bootstrap.sh /usr/local/bin/bootstrap.sh
RUN chmod +x /usr/local/bin/bootstrap.sh

# Must run as the frappe user so bench file ownership is correct.
USER frappe
WORKDIR /home/frappe/frappe-bench
ENTRYPOINT ["/usr/local/bin/bootstrap.sh"]
