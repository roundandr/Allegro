#!/usr/bin/env bash

echo "Removing __pycache__ directories..."
find . -type d -name "__pycache__" -exec rm -rf {} +

echo "Removing .pyc files..."
find . -type f -name "*.pyc" -delete

echo "Done."