// `CashierRepository` поверх единственного Dio-клиента. Ошибки → Failure только через ErrorMapper (06 §6.8).
import 'package:dio/dio.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/network/api_headers.dart';
import 'package:optomstroy/core/network/dto_json.dart';
import 'package:optomstroy/core/network/error_mapper.dart';
import 'package:optomstroy/core/network/models/transaction_dtos.dart' show isoDate;
import 'package:optomstroy/features/cashier/data/dto/pos_dashboard_dtos.dart';
import 'package:optomstroy/features/cashier/domain/entities/pos_dashboard.dart';
import 'package:optomstroy/features/cashier/domain/repositories/cashier_repository.dart';

/// Пути API кассы (08 §4.16).
abstract final class CashierApiPaths {
  static const String dashboard = '/pos/dashboard';
}

final class DioCashierRepository implements CashierRepository {
  DioCashierRepository(this._dio, this._decoders);

  final Dio _dio;
  final DashboardDecoders _decoders;

  @override
  Future<Result<PosDashboard>> dashboard({DateTime? date, String? warehouseId}) => ErrorMapper.guard(() async {
    final Response<Object?> r = await _dio.get<Object?>(
      CashierApiPaths.dashboard,
      queryParameters: <String, Object?>{if (date != null) 'date': isoDate(date), 'warehouseId': ?warehouseId},
      options: apiOptions(),
    );
    return PosDashboardDto.fromJson(jsonObject(r.data), _decoders);
  });
}
