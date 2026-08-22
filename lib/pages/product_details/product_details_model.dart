import '/components/button/button_widget.dart';
import '/components/feature_tag/feature_tag_widget.dart';
import '/components/pickup_card/pickup_card_widget.dart';
import '/flutter_flow/flutter_flow_util.dart';
import '/index.dart';
import 'product_details_widget.dart' show ProductDetailsWidget;
import 'package:flutter/material.dart';

class ProductDetailsModel extends FlutterFlowModel<ProductDetailsWidget> {
  ///  State fields for stateful widgets in this page.

  // Model for FeatureTag.
  late FeatureTagModel featureTagModel1;
  // Model for FeatureTag.
  late FeatureTagModel featureTagModel2;
  // Model for FeatureTag.
  late FeatureTagModel featureTagModel3;
  // Model for PickupCard.
  late PickupCardModel pickupCardModel1;
  // Model for PickupCard.
  late PickupCardModel pickupCardModel2;
  // Model for PickupCard.
  late PickupCardModel pickupCardModel3;
  // Model for Button.
  late ButtonModel buttonModel1;
  // Model for Button.
  late ButtonModel buttonModel2;

  @override
  void initState(BuildContext context) {
    featureTagModel1 = createModel(context, () => FeatureTagModel());
    featureTagModel2 = createModel(context, () => FeatureTagModel());
    featureTagModel3 = createModel(context, () => FeatureTagModel());
    pickupCardModel1 = createModel(context, () => PickupCardModel());
    pickupCardModel2 = createModel(context, () => PickupCardModel());
    pickupCardModel3 = createModel(context, () => PickupCardModel());
    buttonModel1 = createModel(context, () => ButtonModel());
    buttonModel2 = createModel(context, () => ButtonModel());
  }

  @override
  void dispose() {
    featureTagModel1.dispose();
    featureTagModel2.dispose();
    featureTagModel3.dispose();
    pickupCardModel1.dispose();
    pickupCardModel2.dispose();
    pickupCardModel3.dispose();
    buttonModel1.dispose();
    buttonModel2.dispose();
  }
}
