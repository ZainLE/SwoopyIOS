import os

import psycopg2
from psycopg2.extras import RealDictCursor
from supabase import create_client, Client
from werkzeug.local import LocalProxy
from dotenv import load_dotenv
from flask import g

load_dotenv()
__all__ = ['Config', 'init_supabase', 'init_supabase_admin', 'supabase', 'supabase_admin', 'get_sql_cursor']


class Config:
    SECRET_KEY = os.environ.get('SECRET_KEY') or 'dev-key-change-in-production'
    SUPABASE_URL = os.getenv('SUPABASE_URL')
    SUPABASE_KEY = os.getenv('SUPABASE_KEY')
    SUPABASE_SERVICE_ROLE_KEY = os.getenv('SUPABASE_SERVICE_ROLE_KEY')
    DATABASE_URL = os.environ.get('DATABASE_URL') or SUPABASE_URL.replace('https://', 'postgresql://')


def init_supabase() -> Client:
    if "supabase" not in g:
        from flask import current_app
        url = current_app.config['SUPABASE_URL']
        key = current_app.config['SUPABASE_KEY']
        g.supabase = create_client(url, key)
    return g.supabase


def init_supabase_admin() -> Client:
    if "supabase_admin" not in g:
        from flask import current_app
        url = current_app.config['SUPABASE_URL']
        key = current_app.config['SUPABASE_SERVICE_ROLE_KEY']
        g.supabase_admin = create_client(url, key)
    return g.supabase_admin


supabase: Client = LocalProxy(init_supabase)
supabase_admin: Client = LocalProxy(init_supabase_admin)


def get_sql_cursor():
    conn = psycopg2.connect(Config.DATABASE_URL)
    cursor = conn.cursor(cursor_factory=RealDictCursor)
    return conn, cursor
