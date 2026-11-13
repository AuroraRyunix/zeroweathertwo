# STEPS ensemble nowcast service (pysteps), reached over localhost by the Phoenix app in the same pod.
FROM python:3.12-slim AS build
RUN apt-get update && apt-get install -y --no-install-recommends gcc g++ \
 && rm -rf /var/lib/apt/lists/*
RUN python -m venv /opt/venv
ENV PATH=/opt/venv/bin:$PATH
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

FROM python:3.12-slim
COPY --from=build /opt/venv /opt/venv
ENV PATH=/opt/venv/bin:$PATH PYTHONUNBUFFERED=1 MPLBACKEND=Agg MPLCONFIGDIR=/tmp/mpl
WORKDIR /app
COPY engine.py server.py ./
RUN useradd -u 10001 app
USER 10001
EXPOSE 8090
CMD ["python", "server.py"]
