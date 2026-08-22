import '/components/button/button_widget.dart';
import '/components/feature_item/feature_item_widget.dart';
import '/flutter_flow/flutter_flow_util.dart';
import '/index.dart';
import 'onboarding_widget.dart' show OnboardingWidget;
import 'package:flutter/material.dart';

class OnboardingModel extends FlutterFlowModel<OnboardingWidget> {
  ///  State fields for stateful widgets in this page.

  // Model for FeatureItem.
  late FeatureItemModel featureItemModel1;
  // Model for FeatureItem.
  late FeatureItemModel featureItemModel2;
  // Model for FeatureItem.
  late FeatureItemModel featureItemModel3;
  // Model for Button.
  late ButtonModel buttonModel1;
  // Model for Button.
  late ButtonModel buttonModel2;

  @override
  void initState(BuildContext context) {
    featureItemModel1 = createModel(context, () => FeatureItemModel());
    featureItemModel2 = createModel(context, () => FeatureItemModel());
    featureItemModel3 = createModel(context, () => FeatureItemModel());
    buttonModel1 = createModel(context, () => ButtonModel());
    buttonModel2 = createModel(context, () => ButtonModel());
  }

  @override
  void dispose() {
    featureItemModel1.dispose();
    featureItemModel2.dispose();
    featureItemModel3.dispose();
    buttonModel1.dispose();
    buttonModel2.dispose();
  }
}
