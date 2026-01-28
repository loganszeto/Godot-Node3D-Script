This project uses Godot 4 as a programmable 3D scene to generate synthetic training data for computer vision.

Each frame randomizes object placement, camera pose, and lighting, then exports:

RGB render

Segmentation mask (unique color per object)

Metadata JSON (object, camera, and light parameters)

This demonstrates how a real-time engine can act as a controlled data pipeline for AI vision tasks such as detection, pose estimation, and segmentation.

Run

Open main.tscn in Godot 4 and press Play.
Images and metadata are saved to Godot’s user:// directory.
