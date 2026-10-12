FROM python:3.13-slim
WORKDIR /app
COPY app/ /app/
COPY run.py /run.py
RUN mkdir -p /data
EXPOSE 8765
CMD ["python", "-u", "/run.py"]
