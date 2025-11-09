FROM python:3.12-slim

WORKDIR /app

RUN apt-get update && apt-get install -y cron  && rm -rf /var/lib/apt/lists/*

COPY . /app

RUN pip install --no-cache-dir -r requirements.txt

COPY crontab /app/crontab
COPY start.sh /app/start.sh

RUN chmod +x /app/start.sh

RUN mkdir -p /var/log

EXPOSE 5555

CMD ["/app/start.sh"]
