import '/components/bottom_nav/bottom_nav_widget.dart';
import '/components/button/button_widget.dart';
import '/components/category_item/category_item_widget.dart';
import '/components/product_card/product_card_widget.dart';
import '/components/text_field/text_field_widget.dart';
import '/flutter_flow/flutter_flow_util.dart';
import 'marketplace_hub_widget.dart' show MarketplaceHubWidget;
import 'package:flutter/material.dart';

class MarketplaceHubModel extends FlutterFlowModel<MarketplaceHubWidget> {
  ///  State fields for stateful widgets in this page.

  // Model for TextField.
  late TextFieldModel textFieldModel;
  // Model for CategoryItem.
  late CategoryItemModel categoryItemModel1;
  // Model for CategoryItem.
  late CategoryItemModel categoryItemModel2;
  // Model for CategoryItem.
  late CategoryItemModel categoryItemModel3;
  // Model for CategoryItem.
  late CategoryItemModel categoryItemModel4;
  // Model for CategoryItem.
  late CategoryItemModel categoryItemModel5;
  // Model for Button.
  late ButtonModel buttonModel1;
  // Model for ProductCard.
  late ProductCardModel productCardModel1;
  // Model for ProductCard.
  late ProductCardModel productCardModel2;
  // Model for ProductCard.
  late ProductCardModel productCardModel3;
  // Model for ProductCard.
  late ProductCardModel productCardModel4;
  // Model for Button.
  late ButtonModel buttonModel2;
  // Model for BottomNav.
  late BottomNavModel bottomNavModel;

  @override
  void initState(BuildContext context) {
    textFieldModel = createModel(context, () => TextFieldModel());
    categoryItemModel1 = createModel(context, () => CategoryItemModel());
    categoryItemModel2 = createModel(context, () => CategoryItemModel());
    categoryItemModel3 = createModel(context, () => CategoryItemModel());
    categoryItemModel4 = createModel(context, () => CategoryItemModel());
    categoryItemModel5 = createModel(context, () => CategoryItemModel());
    buttonModel1 = createModel(context, () => ButtonModel());
    productCardModel1 = createModel(context, () => ProductCardModel());
    productCardModel2 = createModel(context, () => ProductCardModel());
    productCardModel3 = createModel(context, () => ProductCardModel());
    productCardModel4 = createModel(context, () => ProductCardModel());
    buttonModel2 = createModel(context, () => ButtonModel());
    bottomNavModel = createModel(context, () => BottomNavModel());
  }

  @override
  void dispose() {
    textFieldModel.dispose();
    categoryItemModel1.dispose();
    categoryItemModel2.dispose();
    categoryItemModel3.dispose();
    categoryItemModel4.dispose();
    categoryItemModel5.dispose();
    buttonModel1.dispose();
    productCardModel1.dispose();
    productCardModel2.dispose();
    productCardModel3.dispose();
    productCardModel4.dispose();
    buttonModel2.dispose();
    bottomNavModel.dispose();
  }
}
