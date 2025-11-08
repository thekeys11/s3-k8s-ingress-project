# Instrucciones para Subir el Proyecto a GitHub

## Paso 1: Crear Repositorio en GitHub

1. Ve a https://github.com/new
2. Nombre del repositorio: `s3-k8s-ingress-project` (o el nombre que prefieras)
3. Descripción: "Production-ready solution to expose S3 bucket contents through Kubernetes Ingress using IRSA"
4. Visibilidad: **Public** (para repositorio gratuito)
5. **NO** inicialices con README, .gitignore, o license (ya los tenemos)
6. Click en "Create repository"

## Paso 2: Subir el Código

Desde tu terminal local, ejecuta estos comandos:

```bash
# Navega al directorio del proyecto
cd s3-k8s-ingress-project

# Verifica el estado de Git
git status

# Agrega el remoto de GitHub (reemplaza TU_USUARIO con tu usuario de GitHub)
git remote add origin https://github.com/TU_USUARIO/s3-k8s-ingress-project.git

# Verifica el remoto
git remote -v

# Sube el código a GitHub
git push -u origin master

# O si tu rama principal se llama "main"
git branch -M main
git push -u origin main
```

## Paso 3: Configurar GitHub Actions (Opcional)

Si vas a usar los pipelines de CI/CD, necesitas configurar los siguientes **Secrets** en GitHub:

1. Ve a tu repositorio en GitHub
2. Click en **Settings** > **Secrets and variables** > **Actions**
3. Click en **New repository secret**
4. Agrega los siguientes secrets:

| Secret Name | Descripción | Ejemplo |
|------------|-------------|---------|
| `AWS_ACCOUNT_ID` | Tu ID de cuenta AWS | `123456789012` |
| `AWS_REGION` | Región de AWS | `us-east-1` |
| `AWS_ROLE_ARN` | ARN del rol IAM para GitHub Actions OIDC | `arn:aws:iam::123456789012:role/GitHubActionsRole` |
| `EKS_CLUSTER_NAME` | Nombre de tu cluster EKS | `my-eks-cluster` |
| `S3_BUCKET_NAME` | Nombre del bucket S3 | `my-private-bucket` |
| `ACM_CERTIFICATE_ARN` | ARN del certificado SSL en ACM | `arn:aws:acm:us-east-1:123456789012:certificate/xxx` |

## Paso 4: Configurar GitHub Actions OIDC (Para CI/CD)

Para permitir que GitHub Actions se autentique con AWS sin usar credenciales de larga duración:

### 4.1 Crear Identity Provider en AWS

```bash
# Obtén el thumbprint de GitHub
aws iam create-open-id-connect-provider \
    --url https://token.actions.githubusercontent.com \
    --client-id-list sts.amazonaws.com \
    --thumbprint-list 6938fd4d98bab03faadb97b34396831e3780aea1
```

### 4.2 Crear IAM Role para GitHub Actions

Crea un archivo `github-actions-trust-policy.json`:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::YOUR_ACCOUNT_ID:oidc-provider/token.actions.githubusercontent.com"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
        },
        "StringLike": {
          "token.actions.githubusercontent.com:sub": "repo:YOUR_GITHUB_USER/s3-k8s-ingress-project:*"
        }
      }
    }
  ]
}
```

Luego ejecuta:

```bash
# Crea el rol
aws iam create-role \
    --role-name GitHubActionsRole \
    --assume-role-policy-document file://github-actions-trust-policy.json

# Adjunta políticas necesarias
aws iam attach-role-policy \
    --role-name GitHubActionsRole \
    --policy-arn arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPowerUser

aws iam attach-role-policy \
    --role-name GitHubActionsRole \
    --policy-arn arn:aws:iam::aws:policy/AmazonEKSClusterPolicy

# Puedes necesitar políticas adicionales según tus necesidades
```

## Paso 5: Probar el Deployment

```bash
# Haz un pequeño cambio para probar el pipeline
echo "# Test" >> README.md
git add README.md
git commit -m "test: Trigger CI/CD pipeline"
git push origin main
```

Ve a tu repositorio en GitHub > **Actions** y verás el workflow ejecutándose.

## Paso 6: Personalizar el README

Actualiza el README.md con:
- Tu URL de repositorio real
- Tu dominio real
- Capturas de pantalla (opcional)
- Badge de build status

Ejemplo de badge:
```markdown
![Build Status](https://github.com/TU_USUARIO/s3-k8s-ingress-project/workflows/Build%20and%20Push%20Docker%20Image/badge.svg)
```

## Paso 7: Agregar Topics al Repositorio (Opcional)

En GitHub, ve a tu repositorio y agrega estos topics para mejor visibilidad:

- `kubernetes`
- `aws`
- `s3`
- `nginx`
- `ingress`
- `eks`
- `helm`
- `docker`
- `devops`
- `cloud-native`
- `irsa`
- `gitops`

## Comandos Útiles de Git

```bash
# Ver el log de commits
git log --oneline

# Ver los archivos modificados
git status

# Ver las diferencias
git diff

# Crear una nueva rama para features
git checkout -b feature/nueva-funcionalidad

# Cambiar entre ramas
git checkout main

# Fusionar una rama
git merge feature/nueva-funcionalidad

# Eliminar una rama
git branch -d feature/nueva-funcionalidad

# Sincronizar con GitHub
git pull origin main
```

## Troubleshooting

### Error: "Authentication failed"

Si usas HTTPS y tienes errores de autenticación:

```bash
# Usa un Personal Access Token (PAT)
# 1. Ve a GitHub Settings > Developer settings > Personal access tokens
# 2. Genera un nuevo token con scope "repo"
# 3. Usa el token como password cuando Git lo solicite
```

O cambia a SSH:

```bash
# Cambia el remoto a SSH
git remote set-url origin git@github.com:TU_USUARIO/s3-k8s-ingress-project.git
```

### Error: "Permission denied"

Asegúrate de tener permisos de escritura en el repositorio.

## Verificación Final

Después de subir todo, verifica que:

1. ✅ El código está en GitHub
2. ✅ El README se ve bien en la página principal
3. ✅ Los workflows de GitHub Actions están configurados (si los usas)
4. ✅ Los secrets están configurados correctamente
5. ✅ La documentación es clara y completa

## Recursos Adicionales

- [GitHub Actions Documentation](https://docs.github.com/en/actions)
- [AWS OIDC with GitHub Actions](https://docs.github.com/en/actions/deployment/security-hardening-your-deployments/configuring-openid-connect-in-amazon-web-services)
- [Helm Documentation](https://helm.sh/docs/)
- [Kubernetes Documentation](https://kubernetes.io/docs/)

---

¡Listo! Tu proyecto ahora está en GitHub y listo para ser compartido con el equipo de IE University.

**Nota importante para la entrevista:** Cuando compartas el repositorio con Angel Javier Ripa (ajripa@ie.edu), asegúrate de mencionar:
- La arquitectura implementada (IRSA, NGINX, ALB)
- Las decisiones de diseño y trade-offs
- Las características de seguridad (sin API keys)
- La estrategia de CI/CD
- Las pruebas que realizaste
