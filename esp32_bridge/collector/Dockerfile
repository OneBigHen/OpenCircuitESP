FROM python:3.13-slim
WORKDIR /app
COPY app.py /app/app.py
COPY browser_auth.py health_views.py observations.py archive_tools.py /app/
COPY web/ /app/web/
RUN mkdir -p /data
EXPOSE 8765
HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
  CMD python -c "import urllib.request,sys;sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8765/health',timeout=4).status==200 else 1)"
CMD ["python","-u","/app/app.py"]
