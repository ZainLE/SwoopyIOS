import os
from app import create_app

app = create_app()

if __name__ == '__main__':
    host = os.environ.get('HOST', '0.0.0.0')
    port = int(os.environ.get('PORT', 5555))
    debug = os.environ.get('DEBUG', 'False').lower() == 'true'

    print(f"Starting Flask application on {host}:{port}")
    print(f"Debug mode: {debug}")
    print("Press Ctrl+C to stop the server")

    app.run(host=host, port=port, debug=debug)