FROM alpine:3.22

# pg_dump/pg_restore 16 (misma versión mayor que pgvector/pgvector:*-pg16) y rclone para R2.
RUN apk add --no-cache postgresql16-client rclone ca-certificates tzdata \
    && mkdir -p /root/.config/rclone && touch /root/.config/rclone/rclone.conf

COPY entrypoint.sh backup.sh restore.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/backup.sh /usr/local/bin/restore.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["schedule"]
