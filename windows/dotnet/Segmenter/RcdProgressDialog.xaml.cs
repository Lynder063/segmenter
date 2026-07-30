using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.ComponentModel;
using System.IO;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using Segmenter.Services;
using Wpf.Ui.Controls;
using MessageBox = System.Windows.MessageBox;
using MessageBoxButton = System.Windows.MessageBoxButton;
using MessageBoxImage = System.Windows.MessageBoxImage;
using MessageBoxResult = System.Windows.MessageBoxResult;

namespace Segmenter
{
    public class RcdFileItem : INotifyPropertyChanged
    {
        private string _status = "Waiting";
        private string _icon = "⚪";
        private Brush _statusColor = Brushes.Gray;
        private string _detectionsText = "Waiting";

        public string Name { get; set; } = string.Empty;

        public string Status
        {
            get => _status;
            set { _status = value; OnPropertyChanged(nameof(Status)); }
        }

        public string Icon
        {
            get => _icon;
            set { _icon = value; OnPropertyChanged(nameof(Icon)); }
        }

        public Brush StatusColor
        {
            get => _statusColor;
            set { _statusColor = value; OnPropertyChanged(nameof(StatusColor)); }
        }

        public string DetectionsText
        {
            get => _detectionsText;
            set { _detectionsText = value; OnPropertyChanged(nameof(DetectionsText)); }
        }

        public event PropertyChangedEventHandler? PropertyChanged;
        protected void OnPropertyChanged(string name) => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
    }

    public partial class RcdProgressDialog : FluentWindow
    {
        private readonly string _videoDir;
        private bool _isScanning = false;
        private CancellationTokenSource? _cts;
        private readonly ObservableCollection<RcdFileItem> _fileItems = new ObservableCollection<RcdFileItem>();

        public Dictionary<string, List<(double Start, double End)>>? Results { get; private set; }

        public RcdProgressDialog(string videoDir, Window owner)
        {
            InitializeComponent();
            Owner = owner;
            _videoDir = videoDir;

            StatusLabel.Text = "Ready to start season scan";
            HwStatusText.Text = $"🟢 GPU: {GpuDetector.GpuName} ({GpuDetector.GpuBackend})";

            InitializeFileList();
        }

        private void InitializeFileList()
        {
            try
            {
                var videoExtensions = new HashSet<string>(StringComparer.OrdinalIgnoreCase) { ".mp4", ".mkv", ".avi", ".mov", ".m4v", ".flv", ".webm" };
                if (Directory.Exists(_videoDir))
                {
                    var videos = Directory.GetFiles(_videoDir)
                        .Where(f => videoExtensions.Contains(Path.GetExtension(f)))
                        .Select(Path.GetFileName)
                        .Where(f => f != null)
                        .Cast<string>()
                        .OrderBy(f => f, new NaturalStringComparer())
                        .ToList();

                    _fileItems.Clear();
                    foreach (var v in videos)
                    {
                        _fileItems.Add(new RcdFileItem 
                        { 
                            Name = v, 
                            Status = "Waiting", 
                            Icon = "⚪", 
                            StatusColor = Brushes.Gray, 
                            DetectionsText = "Waiting" 
                        });
                    }
                    FilesListBox.ItemsSource = _fileItems;
                    ProgressDetailsLabel.Text = $"0 of {_fileItems.Count} files processed";
                }
            }
            catch (Exception ex)
            {
                LogArea.AppendText($"[ERROR] Failed to read directory: {ex.Message}{Environment.NewLine}");
            }
        }

        private async void OnStartScanClicked(object sender, RoutedEventArgs e)
        {
            var selectedItem = (ComboBoxItem)DetectionModeCombo.SelectedItem;
            string mode = selectedItem.Tag?.ToString() ?? "CH";

            _isScanning = true;
            StartBtn.IsEnabled = false;
            StartBtn.Content = "Running...";
            DetectionModeCombo.IsEnabled = false;
            ProgressBar.IsIndeterminate = true;
            CloseBtn.Content = "Cancel";

            LogArea.Clear();
            _cts = new CancellationTokenSource();

            // Reset status on items
            foreach (var item in _fileItems)
            {
                item.Status = "Waiting";
                item.Icon = "⚪";
                item.StatusColor = Brushes.Gray;
                item.DetectionsText = "Waiting";
            }

            try
            {
                StatusLabel.Text = $"Running {mode} fingerprinting scan on season...";
                
                var results = await Task.Run(async () =>
                {
                    return await RcdEngine.DetectAsync(
                        _videoDir,
                        mode,
                        (videoIdx, status, msg) => Dispatcher.Invoke(() =>
                        {
                            // Append msg to console
                            LogArea.AppendText(msg + Environment.NewLine);
                            LogArea.ScrollToEnd();

                            // Update corresponding file item
                            if (videoIdx >= 0 && videoIdx < _fileItems.Count)
                            {
                                var item = _fileItems[videoIdx];
                                if (status == "processing")
                                {
                                    item.Status = "Processing";
                                    item.Icon = "🔄";
                                    item.StatusColor = Brushes.Orange;
                                    
                                    // Parse processing details (like frame processed logging)
                                    if (msg.Contains("processed"))
                                    {
                                        int idx = msg.IndexOf("processed");
                                        item.DetectionsText = msg.Substring(idx);
                                    }
                                    else
                                    {
                                        item.DetectionsText = "Extracting...";
                                    }
                                }
                                else if (status == "cached")
                                {
                                    item.Status = "Loaded Cache";
                                    item.Icon = "⚡";
                                    item.StatusColor = Brushes.Cyan;
                                    item.DetectionsText = "Cached";
                                }
                                else if (status == "comparing")
                                {
                                    item.Status = "Comparing";
                                    item.Icon = "📊";
                                    item.StatusColor = Brushes.LightSkyBlue;
                                    item.DetectionsText = "Querying...";
                                }
                                else if (status == "done")
                                {
                                    item.Status = "Completed";
                                    item.Icon = "✅";
                                    item.StatusColor = Brushes.LimeGreen;

                                    if (msg.Contains("Detections for"))
                                    {
                                        item.DetectionsText = "No detections";
                                    }
                                    else if (msg.StartsWith("  "))
                                    {
                                        // If we found a detection, log it as text
                                        if (item.DetectionsText == "No detections" || item.DetectionsText == "Done")
                                        {
                                            item.DetectionsText = msg.Trim();
                                        }
                                        else
                                        {
                                            item.DetectionsText += ", " + msg.Trim();
                                        }
                                    }
                                    else
                                    {
                                        item.DetectionsText = "Done";
                                    }
                                }
                                else if (status == "error")
                                {
                                    item.Status = "Error";
                                    item.Icon = "❌";
                                    item.StatusColor = Brushes.Red;
                                    item.DetectionsText = "Failed";
                                }

                                FilesListBox.ScrollIntoView(item);
                            }

                            // Calculate overall progress bar
                            int doneCount = _fileItems.Count(i => i.Icon == "✅" || i.Icon == "⚡" || i.Icon == "❌");
                            ProgressBar.IsIndeterminate = false;
                            ProgressBar.Value = (double)doneCount / _fileItems.Count * 100.0;
                            ProgressDetailsLabel.Text = $"{doneCount} of {_fileItems.Count} files processed";
                        })
                    );
                }, _cts.Token);

                Results = results;
                ProgressBar.IsIndeterminate = false;
                ProgressBar.Value = 100;
                StatusLabel.Text = "Fingerprinting completed successfully!";
                StatusLabel.Foreground = Brushes.LimeGreen;
                CloseBtn.Content = "Close";
                
                _isScanning = false;
                StartBtn.Content = "Done";
                
                MessageBox.Show(
                    $"Successfully fingerprinted {results.Count} videos!\nDetections have been imported as segment drafts.",
                    "Scan Complete", MessageBoxButton.OK, MessageBoxImage.Information
                );
                
                DialogResult = true;
                Close();
            }
            catch (Exception ex)
            {
                ProgressBar.IsIndeterminate = false;
                ProgressBar.Value = 0;
                StatusLabel.Text = "Error occurred during scan.";
                StatusLabel.Foreground = Brushes.Red;
                LogArea.AppendText($"[ERROR] {ex.Message}{Environment.NewLine}");
                
                _isScanning = false;
                StartBtn.IsEnabled = true;
                StartBtn.Content = "Start Scan";
                DetectionModeCombo.IsEnabled = true;
                CloseBtn.Content = "Close";
            }
        }

        private void OnCloseClicked(object sender, RoutedEventArgs e)
        {
            if (_isScanning)
            {
                var reply = MessageBox.Show(
                    "Are you sure you want to cancel the fingerprint scan?",
                    "Cancel Fingerprint",
                    MessageBoxButton.YesNo,
                    MessageBoxImage.Question
                );

                if (reply == MessageBoxResult.Yes)
                {
                    _cts?.Cancel();
                    Close();
                }
            }
            else
            {
                Close();
            }
        }
    }
}
