using System;
using System.Windows;
using System.Windows.Controls;

namespace Segmenter.Controls
{
    public class SpacingStackPanel : StackPanel
    {
        public static readonly DependencyProperty SpacingProperty =
            DependencyProperty.Register(nameof(Spacing), typeof(double), typeof(SpacingStackPanel),
                new FrameworkPropertyMetadata(0.0, FrameworkPropertyMetadataOptions.AffectsMeasure, OnSpacingChanged));

        public double Spacing
        {
            get => (double)GetValue(SpacingProperty);
            set => SetValue(SpacingProperty, value);
        }

        private static void OnSpacingChanged(DependencyObject d, DependencyPropertyChangedEventArgs e)
        {
            if (d is SpacingStackPanel panel)
            {
                panel.UpdateSpacing();
            }
        }

        public SpacingStackPanel()
        {
            Loaded += (s, e) => UpdateSpacing();
        }

        protected override Size MeasureOverride(Size constraint)
        {
            UpdateSpacing();
            return base.MeasureOverride(constraint);
        }

        private void UpdateSpacing()
        {
            double spacing = Spacing;
            var children = InternalChildren;
            bool isHorizontal = Orientation == Orientation.Horizontal;

            for (int i = 0; i < children.Count; i++)
            {
                var child = children[i] as FrameworkElement;
                if (child == null) continue;

                // Only apply spacing margin if it is not the last visible child
                if (i < children.Count - 1)
                {
                    if (isHorizontal)
                    {
                        child.Margin = new Thickness(child.Margin.Left, child.Margin.Top, spacing, child.Margin.Bottom);
                    }
                    else
                    {
                        child.Margin = new Thickness(child.Margin.Left, child.Margin.Top, child.Margin.Right, spacing);
                    }
                }
            }
        }
    }
}
