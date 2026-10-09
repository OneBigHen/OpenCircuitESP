FROM python:3.13-slim
WORKDIR /app
COPY app.py /app/app.py
COPY browser_auth.py health_views.py /app/
COPY web/ /app/web/
RUN mkdir -p /data
EXPOSE 8765
CMD ["python","-u","/app/app.py"]
