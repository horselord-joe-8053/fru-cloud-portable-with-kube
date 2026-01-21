FROM python:3.11-slim
WORKDIR /app
COPY app/backend/pyproject.toml /app/pyproject.toml
RUN pip install --no-cache-dir -U pip && pip install --no-cache-dir .
COPY app/backend/main.py /app/main.py
COPY data/raw/fridge_sales_with_rating.csv /app/data/raw/fridge_sales_with_rating.csv
ENV PYTHONUNBUFFERED=1
ENV DATA_PATH=/app/data/raw/fridge_sales_with_rating.csv
EXPOSE 8000
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
