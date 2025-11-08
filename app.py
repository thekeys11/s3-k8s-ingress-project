#!/usr/bin/env python3
"""
S3 Content Proxy Application
Exposes private S3 bucket content through HTTP endpoints with JSON logging
"""
import os
import json
import logging
from datetime import datetime
from flask import Flask, request, Response, send_file, jsonify
import boto3
from botocore.exceptions import ClientError
from io import BytesIO

# Configure JSON logging
class JsonFormatter(logging.Formatter):
    def format(self, record):
        log_data = {
            'timestamp': datetime.utcnow().isoformat(),
            'level': record.levelname,
            'message': record.getMessage(),
            'module': record.module,
            'function': record.funcName
        }
        return json.dumps(log_data)

# Setup logger
logger = logging.getLogger(__name__)
logger.setLevel(logging.INFO)
handler = logging.StreamHandler()
handler.setFormatter(JsonFormatter())
logger.addHandler(handler)

# Initialize Flask app
app = Flask(__name__)

# Get configuration from environment variables
BUCKET_NAME = os.environ.get('S3_BUCKET_NAME', 'my-private-bucket')
AWS_REGION = os.environ.get('AWS_REGION', 'us-east-1')

# Initialize S3 client using IAM role (no API keys)
try:
    s3_client = boto3.client('s3', region_name=AWS_REGION)
    logger.info(json.dumps({
        'event': 'initialization',
        'bucket': BUCKET_NAME,
        'region': AWS_REGION
    }))
except Exception as e:
    logger.error(json.dumps({
        'event': 'initialization_failed',
        'error': str(e)
    }))

def log_request(status_code, path, method='GET', error=None):
    """Log HTTP request in JSON format"""
    log_data = {
        'timestamp': datetime.utcnow().isoformat(),
        'event': 'http_request',
        'method': method,
        'path': path,
        'status_code': status_code,
        'client_ip': request.headers.get('X-Forwarded-For', request.remote_addr),
        'user_agent': request.headers.get('User-Agent', 'Unknown')
    }
    if error:
        log_data['error'] = error
    
    logger.info(json.dumps(log_data))

@app.route('/health', methods=['GET'])
def health_check():
    """Health check endpoint"""
    try:
        # Verify S3 access
        s3_client.head_bucket(Bucket=BUCKET_NAME)
        log_request(200, '/health')
        return jsonify({'status': 'healthy', 'bucket': BUCKET_NAME}), 200
    except Exception as e:
        log_request(503, '/health', error=str(e))
        return jsonify({'status': 'unhealthy', 'error': str(e)}), 503

@app.route('/', defaults={'path': ''})
@app.route('/<path:path>')
def serve_s3_content(path):
    """Serve content from S3 bucket"""
    try:
        # Default to index.html if path is empty or ends with /
        if not path or path.endswith('/'):
            path = path + 'index.html' if path else 'index.html'
        
        # Get object from S3
        s3_object = s3_client.get_object(Bucket=BUCKET_NAME, Key=path)
        
        # Read content
        content = s3_object['Body'].read()
        content_type = s3_object.get('ContentType', 'application/octet-stream')
        
        log_request(200, f'/{path}')
        
        return Response(content, mimetype=content_type)
    
    except ClientError as e:
        error_code = e.response['Error']['Code']
        if error_code == 'NoSuchKey':
            # Try listing directory if path might be a prefix
            try:
                response = s3_client.list_objects_v2(
                    Bucket=BUCKET_NAME,
                    Prefix=path if path.endswith('/') else path + '/',
                    Delimiter='/'
                )
                
                if 'Contents' in response or 'CommonPrefixes' in response:
                    # Return directory listing as JSON
                    files = [obj['Key'] for obj in response.get('Contents', [])]
                    dirs = [p['Prefix'] for p in response.get('CommonPrefixes', [])]
                    
                    log_request(200, f'/{path}')
                    return jsonify({
                        'path': path,
                        'directories': dirs,
                        'files': files
                    }), 200
            except Exception:
                pass
            
            log_request(404, f'/{path}', error='Not Found')
            return jsonify({'error': 'File not found'}), 404
        else:
            log_request(500, f'/{path}', error=str(e))
            return jsonify({'error': 'Internal server error'}), 500
    
    except Exception as e:
        log_request(500, f'/{path}', error=str(e))
        return jsonify({'error': 'Internal server error', 'details': str(e)}), 500

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=8080, debug=False)
