FROM python:3.12-slim
RUN pip install --no-cache-dir docker boto3
COPY forward.py /forward.py
CMD ["python", "/forward.py"]
