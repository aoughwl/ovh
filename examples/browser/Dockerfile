# One browser session. Each pool session gets its own container, its own
# network namespace (isolated bridge), its own /tmp profile and, optionally,
# its own egress IP. AOWL_SESSION tells the driver which session it is.
FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends chromium ca-certificates dumb-init \
 && rm -rf /var/lib/apt/lists/* && useradd -m bot
USER bot
EXPOSE 9222
ENTRYPOINT ["dumb-init", "--"]
CMD ["chromium", "--headless=new", "--no-sandbox", "--disable-gpu", "--user-data-dir=/tmp/profile", \
     "--remote-debugging-address=0.0.0.0", "--remote-debugging-port=9222", "about:blank"]
