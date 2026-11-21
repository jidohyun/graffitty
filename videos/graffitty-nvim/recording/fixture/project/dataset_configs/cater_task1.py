import os

import numpy as np

from config import DATA_DIR

num_classes = 14

# Paths
dataset_root = os.path.join(DATA_DIR, "cater/max2action")
frames_splits_dir = os.path.join(dataset_root, "splits_frames/actions_present")
split_file_basename = {"train": "train.txt", "val": "val.txt"}
split2mode = {"train": "train", "val": "val", "test": "test"}

# Training settings
horizontal_flip = True


def count_train_class_frequency():
    """Count class frequency in training data."""
    return np.ones(num_classes, dtype=int)
