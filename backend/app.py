from flask import Flask, jsonify
from flask_cors import CORS
import socket

app = Flask(__name__)
CORS(app) # Importante para que el frontend no tenga errores de seguridad

@app.route('/api/hola', methods=['GET'])
def hola_mundo():
    # Obtenemos el ID para saber qué máquina responde
    hostname = socket.gethostname()
    return jsonify({
        "mensaje": "Hola desde el Backend (Python)",
        "servidor": hostname
    })

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5000)