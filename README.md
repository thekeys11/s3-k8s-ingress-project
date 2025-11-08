# Exposición de Bucket S3 mediante Kubernetes Ingress

## Descripción General

Esta solución expone el contenido de un bucket S3 privado de AWS a través de un recurso Kubernetes Ingress utilizando NGINX como proxy inverso. con esta solucion se implementa una carga de trabajo contenerizada que sirve objetos de S3 en el nivel raíz del FQDN del Ingress sin requerir claves API de AWS, utilizando IAM Roles for Service Accounts (IRSA) para autenticación segura.

## Arquitectura

La solución consta de los siguientes componentes:

1. **Contenedor NGINX**: Actúa como proxy inverso con integración backend a S3 utilizando autenticación AWS Signature V4
2. **IAM Role para Service Account (IRSA)**: Proporciona acceso seguro a S3 sin claves
3. **Kubernetes Deployment**: Gestiona los pods de NGINX con la configuración apropiada
4. **Kubernetes Service**: Expone el deployment internamente
5. **Kubernetes Ingress**: Enruta el tráfico externo hacia el servicio
6. **AWS Load Balancer Controller**: Gestiona el ALB para los recursos de Ingress

## Detalles de Implementación

### Enfoque de Autenticación

Se eligio por solicitud del proyecto implementar IRSA (IAM Roles for Service Accounts) en lugar de usar claves API estáticas. Este enfoque proporciona varias ventajas:

- **Seguridad**: Sin almacenamiento de credenciales en código o ConfigMaps
- **Rotación automática**: AWS gestiona el ciclo de vida de las credenciales
- **Permisos granulares**: Las políticas IAM controlan el acceso exacto a S3
- **Pista de auditoría**: CloudTrail registra todos los intentos de acceso

### Patrón de Acceso a S3

El contenedor NGINX utiliza el módulo `ngx_http_s3_auth` para firmar solicitudes con AWS Signature V4. El módulo recupera automáticamente las credenciales temporales del rol IAM de EKS asociado con el ServiceAccount.

### Registro de Logs

Todas las solicitudes HTTP se registran en formato JSON utilizando el formato de log personalizado de NGINX, incluyendo:

- Marca de tiempo de la solicitud
- Dirección IP del cliente
- Método y ruta de la solicitud
- Código de estado de respuesta
- Tiempo de procesamiento de la solicitud
- Agente de usuario

## Requisitos Previos

Antes de implementar esta solución, asegúrate de tener:

- Una cuenta de AWS con permisos apropiados
- Un cluster EKS en ejecución (single-AZ o multi-AZ)
- `kubectl` configurado para acceder a tu cluster
- CLI de `helm` instalado (versión 3.x)
- AWS CLI configurado
- Un bucket S3 creado (lo referenciaré como `my-private-bucket`)
- AWS Load Balancer Controller instalado en tu cluster

## Pasos de Instalación

### 1. Instalar AWS Load Balancer Controller (si no está instalado)

```bash
helm repo add eks https://aws.github.io/eks-charts
helm repo update
helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=nombre-de-tu-cluster
```

### 2. Crear Política IAM para Acceso a S3

```bash
aws iam create-policy \
  --policy-name S3BucketReadPolicy \
  --policy-document file://iam/s3-policy.json
```

### 3. Crear Rol IAM y Service Account

```bash
eksctl create iamserviceaccount \
  --name s3-reader-sa \
  --namespace default \
  --cluster nombre-de-tu-cluster \
  --attach-policy-arn arn:aws:iam::TU_ACCOUNT_ID:policy/S3BucketReadPolicy \
  --approve \
  --override-existing-serviceaccounts
```

### 4. Desplegar Usando Helm

```bash
# Actualiza values.yaml con el nombre de tu bucket y dominio
helm install s3-ingress-app ./helm-chart \
  --set s3.bucketName=my-private-bucket \
  --set ingress.host=s3-app.example.com
```

### 5. Verificar el Despliegue

```bash
# Verificar que los pods están ejecutándose
kubectl get pods -l app=s3-nginx

# Verificar el servicio
kubectl get svc s3-nginx-service

# Verificar el ingress
kubectl get ingress s3-nginx-ingress

# Obtener el nombre DNS del ALB
kubectl get ingress s3-nginx-ingress -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
```

## Prueba de la Solución

### 1. Subir Archivos de Prueba a S3

```bash
echo "¡Hola desde S3!" > test.html
aws s3 cp test.html s3://my-private-bucket/test.html

echo '{"mensaje": "Respuesta JSON desde S3"}' > data.json
aws s3 cp data.json s3://my-private-bucket/data.json
```

### 2. Configurar DNS

Apunta el dominio (ej., `s3-app.example.com`) al nombre DNS del ALB obtenido del ingress.

### 3. Probar el Acceso

```bash
# Probar archivo HTML
curl https://s3-app.example.com/test.html

# Probar archivo JSON
curl https://s3-app.example.com/data.json

# Probar listado de directorio (si está habilitado)
curl https://s3-app.example.com/
```

### 4. Revisar los Logs

```bash
# Ver logs en formato JSON
kubectl logs -l app=s3-nginx --tail=50

# Seguir logs en tiempo real
kubectl logs -l app=s3-nginx -f
```

## Pipeline CI/CD

Inclui workflows de GitHub Actions para despliegue automatizado:

1. **Pipeline de Build** (`.github/workflows/build.yml`):
   - Construye la imagen Docker
   - Ejecuta escaneos de seguridad
   - Sube a ECR

2. **Pipeline de Deploy** (`.github/workflows/deploy.yml`):
   - Despliega al ambiente de staging
   - Ejecuta pruebas de integración
   - Promociona a producción con aprobación

Para usar el pipeline CI/CD:

1. Configura GitHub Secrets:
   - `AWS_ACCOUNT_ID`
   - `AWS_REGION`
   - `EKS_CLUSTER_NAME`
   - `S3_BUCKET_NAME`

2. Realiza push de cambios para activar builds:
   - Push a la rama `main` activa despliegue a staging
   - Crear un tag de release activa despliegue a producción

## Decisiones de Diseño y Trade-offs

### ¿Por Qué NGINX en Lugar de Código de Aplicación?

Elegí NGINX como capa de proxy porque:

- **Rendimiento**: NGINX maneja eficientemente el servicio de contenido estático
- **Confiabilidad probada**: Probado en batalla en ambientes de producción
- **Integración nativa con S3**: Módulos incorporados para autenticación S3
- **Huella de recursos baja**: Requisitos mínimos de CPU/memoria

**Trade-off**: Menos flexibilidad que código de aplicación personalizado, pero mucho mejor rendimiento y estabilidad.

### ¿Por Qué IRSA en Lugar de Claves de Usuario IAM?

IRSA proporciona:

- **Seguridad**: Sin credenciales de larga duración que gestionar o filtrar
- **Cumplimiento**: Cumple con mejores prácticas de seguridad y requisitos de auditoría
- **Simplicidad**: Rotación automática de credenciales manejada por AWS

**Trade-off**: Requiere cluster EKS con proveedor OIDC configurado, agrega complejidad de configuración inicial.

### Monolítico vs. Microservicios

Se desplega un solo contenedor NGINX en lugar de contenedores separados para autenticación y servicio porque:

- **Simplicidad**: Más fácil de gestionar y solucionar problemas
- **Menor latencia**: Sin sobrecarga de comunicación entre servicios
- **Suficiente para el caso de uso**: Los requisitos no justifican la complejidad de microservicios

**Trade-off**: Menos flexibilidad para escalado independiente de componentes, pero operaciones más simples.

## Monitoreo y Observabilidad

La solución incluye:

- **Logs JSON**: Registro estructurado para fácil análisis y parseo
- **Probes de Readiness/Liveness**: Health checks de Kubernetes
- **Límites de recursos**: Previene agotamiento de recursos
- **Endpoint de métricas**: Listo para integración con Prometheus

## Consideraciones de Seguridad

- El bucket S3 permanece privado; sin acceso público
- Toda la comunicación usa TLS (gestionado por ALB)
- IRSA proporciona acceso de privilegio mínimo
- Sin secretos almacenados en Git o manifiestos
- Headers de seguridad configurados en NGINX

## Solución de Problemas

### Pods no inician

```bash
kubectl describe pod -l app=s3-nginx
kubectl logs -l app=s3-nginx
```

### 403 Forbidden desde S3

Se debe verificar los permisos del rol IAM:

```bash
kubectl describe sa s3-reader-sa
```

### Ingress no crea ALB

Debes asegurarte de que AWS Load Balancer Controller esté ejecutándose:

```bash
kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller
```

## Mejoras Futuras

- Agregar capa de caché (CloudFront o Varnish)
- Implementar autenticación/autorización de solicitudes
- Agregar limitación de tasa
- Integrar con AWS CloudWatch para métricas
- Soporte para múltiples buckets S3
- Estrategia de despliegue blue/green

## Estructura del Repositorio

```
.
├── README.md
├── docker/
│   ├── Dockerfile
│   └── nginx.conf
├── helm-chart/
│   ├── Chart.yaml
│   ├── values.yaml
│   └── templates/
│       ├── deployment.yaml
│       ├── service.yaml
│       ├── ingress.yaml
│       ├── serviceaccount.yaml
│       └── configmap.yaml
├── kubernetes/
│   └── manifests/
│       ├── deployment.yaml
│       ├── service.yaml
│       ├── ingress.yaml
│       ├── serviceaccount.yaml
│       └── configmap.yaml
├── iam/
│   └── s3-policy.json
└── .github/
    └── workflows/
        ├── build.yml
        └── deploy.yml
```

---

**Autor**: Oscar - Ingeniero Cloud  
**Fecha**: Noviembre 2025  