import os
import cv2
from tqdm import tqdm
import pickle
import numpy as np
from math import sqrt

def get_frame(frame_index, video):
    """
    Given a frame position number and the videocapture variable, returns the frame as an image object (numpy array)
    """
    video.set(1,frame_index)
    _, img = video.read()

    return img

fouriers = [
    [1,1,1,1,1,1,1,1],
    [-1,1,-1,1,1,-1,1,-1], 
    [-sqrt(2)/2, 0, sqrt(2)/2, -1, 1, -sqrt(2)/2,0,sqrt(2)/2],
    [-sqrt(2)/2, -1, -sqrt(2)/2, 0, 0, sqrt(2)/2, 1, sqrt(2)/2], 
    [0, -1, 0, 1, 1, 0, -1, 0],
    [1,0,-1, 0, 0, -1, 0, 1],
    [sqrt(2)/2, 0 , -sqrt(2)/2, -1, 1, sqrt(2)/2, 0, -sqrt(2)/2],
    [-sqrt(2)/2, 1, -sqrt(2)/2, 0, 0, sqrt(2)/2, -1, sqrt(2)/2]
]

for i,f in enumerate(fouriers):
    f.insert(4,0)
    fouriers[i] = np.array(f)
    fouriers[i] = fouriers[i].reshape((3,3)).astype('float32')

max_vals = []
for f in fouriers:
    m = np.array([255])
    m = cv2.matchTemplate(m.astype('float32'),f, cv2.TM_CCORR).clip(0,255)
    max_vals.append(cv2.matchTemplate(m.astype('float32'),f, cv2.TM_CCORR)[0][0])

def color_texture_moments(img):
    img = cv2.cvtColor(img, cv2.COLOR_BGR2HSV)
    result = []
    for channel in range(0,3):
        for template, max_val in zip(fouriers, max_vals):
            r = cv2.matchTemplate(img[:,:,channel].astype('float32'),template, cv2.TM_CCORR)
            
            r = r / max_val
            result.append(r.mean())
            result.append(r.std())
                            
    return result

def get_img_color_hist(image, binsize):
    """
    Given an image as input, output its color histogram as a numpy array.
    Binsize will determine the size
    """

    chans = cv2.split(image)
    main = np.zeros((0,1))

    # loop over the image channels
    for chan in chans:
        # create a histogram for the current channel and
        # concatenate the resulting histograms for each
        # channel
        hist = cv2.calcHist([chan], [0], None, [binsize], [0, 256])
        main = np.append(main,hist)

    #normalize so sum of all values equals 1
    main = main / (image.shape[0] * image.shape[1])

    return main.astype('float32')

# Import unified GPU detection
import sys, os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))
from gpu import GPU_AVAILABLE as HAS_TORCH_CUDA, get_device

_cnn_model = None

def get_cnn_model():
    global _cnn_model
    if _cnn_model is not None:
        return _cnn_model
        
    device = get_device()
    
    # Try torchvision
    try:
        import torchvision.models as models
        try:
            weights = models.MobileNet_V3_Small_Weights.DEFAULT
            model = models.mobilenet_v3_small(weights=weights)
        except AttributeError:
            model = models.mobilenet_v3_small(pretrained=True)
        model.classifier = torch.nn.Identity()
        model.eval()
        model.to(device)
        _cnn_model = (model, "torchvision", device)
        return _cnn_model
    except Exception:
        pass
        
    # Fallback to custom simple CNN
    try:
        import torch.nn as nn
        class SimpleCNN(nn.Module):
            def __init__(self):
                super().__init__()
                self.features = nn.Sequential(
                    nn.Conv2d(3, 16, kernel_size=3, stride=2, padding=1),
                    nn.ReLU(),
                    nn.Conv2d(16, 32, kernel_size=3, stride=2, padding=1),
                    nn.ReLU(),
                    nn.Conv2d(32, 64, kernel_size=3, stride=2, padding=1),
                    nn.ReLU(),
                    nn.AdaptiveAvgPool2d((4, 4))
                )
            def forward(self, x):
                return self.features(x).view(x.size(0), -1)
        
        model = SimpleCNN()
        model.eval()
        model.to(device)
        _cnn_model = (model, "simple_cnn", device)
        return _cnn_model
    except Exception:
        pass
        
    _cnn_model = (None, "none", device)
    return _cnn_model

def cnn_extractor(img):
    try:
        import torch
    except ImportError:
        return color_hist(img)
        
    model, model_type, device = get_cnn_model()
    if model is None:
        return color_hist(img)
        
    try:
        # Convert BGR to RGB and format to (C, H, W)
        rgb = cv2.cvtColor(img, cv2.COLOR_BGR2RGB)
        tensor = torch.from_numpy(rgb).permute(2, 0, 1).float() / 255.0
        
        if model_type == "torchvision":
            mean = torch.tensor([0.485, 0.456, 0.406]).view(3, 1, 1)
            std = torch.tensor([0.229, 0.224, 0.225]).view(3, 1, 1)
            tensor = (tensor - mean) / std
            
        tensor = tensor.unsqueeze(0).to(device)
        
        with torch.no_grad():
            feats = model(tensor)
            feat_vec = feats.squeeze(0).cpu().numpy().astype('float32')
        return feat_vec
    except Exception as e:
        print(f"[CNN Extractor] Error running model: {e}. Falling back to Color Histogram.")
        return color_hist(img)

def color_hist_gpu(image):
    # Transfer image to GPU (works for both CUDA and ROCm)
    device = get_device()
    img_tensor = torch.from_numpy(image).to(device, non_blocking=True).float()
    
    # Calculate histogram for each channel on GPU
    hists = []
    for i in range(3):
        chan = img_tensor[:, :, i]
        hist = torch.histc(chan, bins=100, min=0.0, max=256.0)
        hists.append(hist)
        
    main = torch.cat(hists)
    main = main / (image.shape[0] * image.shape[1])
    return main.cpu().numpy()

def color_hist(img):
    if HAS_TORCH_CUDA:
        try:
            return color_hist_gpu(img)
        except Exception:
            pass
    result = get_img_color_hist(img, 100)
    return result

def construct_feature_vectors(video_fn, result_dir_name, vector_function, framejump):
    """
    Function that converts a video file to a list of feature vectors,
    which it then writes to a pickle file.
    """
    
    base_video_fn = os.path.basename(video_fn)
    video = cv2.VideoCapture(video_fn)
    series_dir = os.path.dirname(video_fn)
    vectors_fn = os.path.join(series_dir, result_dir_name, base_video_fn + ".p")

    # set correct vector function to apply
    if vector_function == "CH":
        vector_function = color_hist
    elif vector_function == "CTM":
        vector_function = color_texture_moments
    elif vector_function == "CNN":
        vector_function = cnn_extractor

    # make sure folder of experimentname exists or create otherwise
    os.makedirs(os.path.dirname(vectors_fn), exist_ok=True)

    # check if histograms exist, else create them and save to pickle
    if not os.path.isfile(vectors_fn):

        # construct the histograms from frames at the start of scenes
        feature_vectors = []
        total = int(video.get(cv2.CAP_PROP_FRAME_COUNT) / framejump) - 1

        # apply the vector function for every xth frame determined by framejump
        for i in tqdm(range(total)):
            img = get_frame(i * framejump, video)
            feature_vector = vector_function(img)
            feature_vectors.append(feature_vector)
            
        # save to pickle file
        with open(vectors_fn, 'wb') as handle:
            pickle.dump(feature_vectors, handle, protocol=2)