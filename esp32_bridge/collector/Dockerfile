FROM python:3.13-slim
WORKDIR /app
COPY app.py /app/app.py
RUN mkdir -p /data
EXPOSE 8765
CMD ["python","-u","/app/app.py"]
