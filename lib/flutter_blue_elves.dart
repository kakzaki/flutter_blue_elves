
import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'dart:io';

class FlutterBlueElves {
  static FlutterBlueElves instance=FlutterBlueElves._();
  MethodChannel _channel;
  EventChannel _eventChannelPlugin;
  StreamSubscription _eventStreamSubscription;
  StreamController<ScanResult> _scanResultStreamController;
  Function(bool isOk) _androidApplyLocationPermissionCallback;
  Function(bool isOk) _androidOpenLocationServiceCallback;
  Function(bool isOk) _androidOpenBluetoothServiceCallback;
  Map<String,Device> _deviceCache;

  /// 将构造函数私有化
  FlutterBlueElves._(){
    _deviceCache={};
    _channel=const MethodChannel("flutter_blue_elves/method");
    _eventChannelPlugin=const EventChannel("flutter_blue_elves/event");//定义接收底层操作系统主动发来的消息通道;
    _eventStreamSubscription=_eventChannelPlugin
        .receiveBroadcastStream()
        .listen(_onToDart, onError: _onToDartError);//注册消息回调函数;//广播流来处理EventChannel发来的消息
  }

  Future<IosBluetoothState> iosCheckBluetoothState() {//调用底层去查看蓝牙当前状态,ios专用
    return _channel.invokeMethod('checkBluetoothState').then((state){
      if(state==0) {
        return IosBluetoothState.unKnown;
      } else if(state==1) {
        return IosBluetoothState.resetting;
      }else if(state==2) {
        return IosBluetoothState.unSupport;
      }else if(state==3) {
        return IosBluetoothState.unAuthorized;
      }else if(state==4) {
        return IosBluetoothState.poweredOff;
      }else {
        return IosBluetoothState.poweredOn;
      }
    });
  }

  Future<List<AndroidBluetoothLack>> androidCheckBlueLackWhat() {//调用底层去查看缺少什么权限或功能,安卓专用
    return _channel.invokeMethod('checkBlueLackWhat').then((lacks){
      List<AndroidBluetoothLack> result=[];
      if(lacks.contains(0)) {
        result.add(AndroidBluetoothLack.locationPermission);
      } else if(lacks.contains(1)) {
        result.add(AndroidBluetoothLack.locationFunction);
      } else if(lacks.contains(2)) {
        result.add(AndroidBluetoothLack.bluetoothFunction);
      }
      return result;
    });
  }

  void androidApplyLocationPermission(Function(bool isOk) callback) {//调用底层去跟获取定位权限,安卓专用
    _androidApplyLocationPermissionCallback=callback;
    _channel.invokeMethod('applyLocationPermission');
  }

  void androidOpenLocationService(Function(bool isOk) callback) {//调用底层去跟开启定位功能,安卓专用
    _androidOpenLocationServiceCallback=callback;
    _channel.invokeMethod('openLocationService');
  }

  void androidOpenBluetoothService(Function(bool isOk) callback) {//调用底层去跟开启蓝牙功能,安卓专用
    _androidOpenBluetoothServiceCallback=callback;
    _channel.invokeMethod('openBluetoothService');
  }

  Stream<ScanResult> startScan(int timeout,{bool isAllowDuplicates=false})  {
    _scanResultStreamController=StreamController<ScanResult>(onListen:(){
      _channel.invokeMethod('startScan',{"isAllowDuplicates":isAllowDuplicates,"timeout":Platform.isAndroid?timeout:timeout~/1000});
    },onCancel: stopScan);
    return _scanResultStreamController.stream;
  }

  void stopScan(){
    _channel.invokeMethod('stopScan');
    _scanResultStreamController.close();
  }

  void _onToDart(dynamic message) {//底层发送成功消息时会进入到这个函数来接收
    print(message);
    switch(message['eventName']){
      case "allowLocationPermission":
        _androidApplyLocationPermissionCallback(true);
        break;
      case "denyLocationPermission":
        _androidApplyLocationPermissionCallback(false);
        break;
      case "allowLocationFunction":
        _androidOpenLocationServiceCallback(true);
        break;
      case "denyLocationFunction":
        _androidOpenLocationServiceCallback(false);
        break;
      case "allowOpenBluetooth":
        _androidOpenBluetoothServiceCallback(true);
        break;
      case "denyOpenBluetooth":
        _androidOpenBluetoothServiceCallback(false);
        break;
      case "scanResult":
        ScanResult item=ScanResult._(message['id'],message['name'],message['localName'],message['macAddress'], message['rssi'],message['uuids'],message['manufacturerSpecificData'], message['scanRecord']);
        _scanResultStreamController.add(item);//将扫描到的新设备放到流中通知
        break;
      case "scanTimeout":
        _scanResultStreamController.close();//扫描时间到了就关闭流,因为是单对单的流
        break;
      case "connected":
        Device deviceCache= _deviceCache[message['id']];
        if(deviceCache!=null) {
          deviceCache._stateStreamController.add(DeviceState.connected);//广播设备状态变化
          deviceCache._state=DeviceState.connected;//将设备状态设置为已连接
        }
        break;
      case "connectTimeout":
        Device deviceCache= _deviceCache[message['id']];
        if(deviceCache!=null) {
          deviceCache._stateStreamController.add(DeviceState.connectTimeout);//广播设备连接超时的信息
          deviceCache._state=DeviceState.disconnected;//将设备状态设置为未连接
        }
        break;
      case "initiativeDisConnected"://如果是手动断开连接
        Device deviceCache= _deviceCache[message['id']];
        if(deviceCache!=null) {
          deviceCache._stateStreamController.add(DeviceState.initiativeDisConnected);//广播设备状态变化
          deviceCache._state=DeviceState.initiativeDisConnected;//将设备状态设置为手动断开连接
        }
        break;
      case "disConnected"://如果是被动断开连接
        Device deviceCache= _deviceCache[message['id']];
        if(deviceCache!=null) {
          deviceCache._stateStreamController.add(DeviceState.disconnected);//广播设备状态变化
          deviceCache._state=DeviceState.disconnected;//将设备状态设置为被动断开连接
        }
        break;
      case "discoverService"://如果是发现了服务
        Device deviceCache= _deviceCache[message['id']];
        if(deviceCache!=null) {
          List characteristicsList=message['characteristic'];//底层发现的特征值列表信息
          List<BleCharacteristic> bleCharacteristicsList=[];
          for(int i=0;i<characteristicsList.length;i++){//将特征值信息封装成对象
            Map characteristicsMap=characteristicsList[i];
            int properties=characteristicsMap["properties"];//底层发现的特征值的properties
            List<CharacteristicProperties> propertiesObject=[];
            if(properties&0x01>0) {
              propertiesObject.add(CharacteristicProperties.broadcast);
            }
            if(properties&0x02>0) {
              propertiesObject.add(CharacteristicProperties.read);
            }
            if(properties&0x04>0) {
              propertiesObject.add(CharacteristicProperties.writeNoResponse);
            }
            if(properties&0x08>0) {
              propertiesObject.add(CharacteristicProperties.write);
            }
            if(properties&0x10>0) {
              propertiesObject.add(CharacteristicProperties.notify);
            }
            if(properties&0x20>0) {
              propertiesObject.add(CharacteristicProperties.indicate);
            }
            if(properties&0x40>0) {
              propertiesObject.add(CharacteristicProperties.signedWrite);
            }
            if(properties&0x80>0) {
              propertiesObject.add(CharacteristicProperties.extendedProps);
            }
            if(properties&0x100>0) {
              propertiesObject.add(CharacteristicProperties.notifyEncryptionRequired);
            }
            if(properties&0x200>0) {
              propertiesObject.add(CharacteristicProperties.indicateEncryptionRequired);
            }
            List<BleDescriptor> bleDescriptors=[];
            List descriptorsList=characteristicsMap['descriptors'];//底层发现的特征值描述列表信息
            for(int j=0;j<descriptorsList.length;j++){
              Map descriptorMap=descriptorsList[j];
              bleDescriptors.add(BleDescriptor(descriptorMap['uuid']));
            }
            bleCharacteristicsList.add(BleCharacteristic(characteristicsMap["uuid"], propertiesObject,bleDescriptors));
          }
          deviceCache._serviceDiscoveryStreamController.add(BleService(message['serviceUuid'], bleCharacteristicsList));//广播发现的新服务和特征值信息
        }
        break;
      case "deviceSignal"://如果是设备传来数据
        Device deviceCache= _deviceCache[message['id']];
        if(deviceCache!=null){
          DeviceSignalType type=DeviceSignalType.unKnown;
          switch(message['type']){
            case 0:
              type=DeviceSignalType.characteristicsRead;
              break;
            case 1:
              type=DeviceSignalType.characteristicsWrite;
              break;
            case 2:
              type=DeviceSignalType.characteristicsNotify;
              break;
            case 3:
              type=DeviceSignalType.descriptorRead;
              break;
            case 4:
              type=DeviceSignalType.descriptorWrite;
              break;
          }
          deviceCache._deviceSignalResultStreamController.add(DeviceSignalResult(type, message['uuid'], message['isSuccess'], message['data']));
        }
        break;
    }
  }
  void _onToDartError(dynamic error) {//底层发送错误消息时会进入到这个函数来接收
    print(error);
  }

}

class Device{
  final String _id;//设备Id
  DeviceState _state;
  StreamController<DeviceState> _stateStreamController;
  Stream<DeviceState> _stateStream;
  StreamController<BleService> _serviceDiscoveryStreamController;
  Stream<BleService> _serviceDiscoveryStream;
  StreamController<DeviceSignalResult> _deviceSignalResultStreamController;
  Stream<DeviceSignalResult> _deviceSignalResultStream;

  Device._(this._id){
    _state=DeviceState.disconnected;
    _stateStreamController=StreamController<DeviceState>();
    _stateStream=_stateStreamController.stream.asBroadcastStream();
    _serviceDiscoveryStreamController=StreamController<BleService>();
    _serviceDiscoveryStream=_serviceDiscoveryStreamController.stream.asBroadcastStream();
    _deviceSignalResultStreamController=StreamController<DeviceSignalResult>();
    _deviceSignalResultStream=_deviceSignalResultStreamController.stream.asBroadcastStream();
  }

  //销毁设备对象,不然可能会存在重复的设备对象,当
  void destroy(){
    if(_state!=DeviceState.destroyed){
      _state=DeviceState.destroyed;//将设备状态置为已销毁
      _stateStreamController.add(DeviceState.destroyed);//广播状态变化
      FlutterBlueElves.instance._deviceCache.remove(_id);//从cache中移除
      FlutterBlueElves.instance._channel.invokeMethod('destroy',{"id":_id});//销毁底层的设备对象
      _stateStreamController.close();//关闭流
      _serviceDiscoveryStreamController.close();//关闭流
      _deviceSignalResultStreamController.close();//关闭流
    }
  }

  DeviceState get state => _state;

  /// 连接设备
  void connect({connectTimeout=0}){
    if(_state!=DeviceState.destroyed&&(_state==DeviceState.disconnected||_state==DeviceState.initiativeDisConnected)) {//未连接才能去连接
      _state=DeviceState.connecting;//将设备状态置为连接中
      _stateStreamController.add(DeviceState.connecting);//广播状态变化
      FlutterBlueElves.instance._channel.invokeMethod('reConnect',{"id":_id,"timeout":Platform.isAndroid?connectTimeout:connectTimeout~/1000});//重连该设备
    }
  }

  /// 与设备断开连接
  void disConnect(){
    if(_state!=DeviceState.destroyed&&_state==DeviceState.connected) {//已连接才能去断开连接
      _state=DeviceState.disConnecting;//将设备状态置为断开连接中
      _stateStreamController.add(DeviceState.disConnecting);//广播状态变化
      FlutterBlueElves.instance._channel.invokeMethod('disConnect',{"id":_id});//去与该设备断开连接
    }
  }

  ///获取设备状态变化流
  Stream<DeviceState> get stateStream => _stateStream;

  ///发现设备服务
  void discoveryService(){
    if(_state!=DeviceState.destroyed&&_state==DeviceState.connected) { //已连接才能去发现服务
      FlutterBlueElves.instance._channel.invokeMethod('discoverService',{"id":_id});//去发现服务
    }
  }

  ///获取设备蓝牙服务发现流
  Stream<BleService> get serviceDiscoveryStream => _serviceDiscoveryStream;

  ///设置对应的notify特征值的通知
  ///返回true代表设置成功,false代表设置失败
  Future<bool> setNotify(String serviceUuid,String characteristicUuid,bool isEnable) async{
    bool result=false;
    if(_state!=DeviceState.destroyed&&_state==DeviceState.connected) { //已连接才能去设置notify的通知
      await FlutterBlueElves.instance._channel.invokeMethod('setNotify',{"id":_id,"serviceUuid":serviceUuid,"characteristicUuid":characteristicUuid,"isEnable":isEnable}).then((value) => result=value);//去设置notify
    }
    return result;
  }

  ///使用设备的read特征值去向设备读取数据
  void readData(String serviceUuid,String characteristicUuid){
    if(_state!=DeviceState.destroyed&&_state==DeviceState.connected) { //已连接才能去向设备写入数据
      FlutterBlueElves.instance._channel.invokeMethod('readData',{"id":_id,"serviceUuid":serviceUuid,"characteristicUuid":characteristicUuid});//去向设备读取数据
    }
  }

  ///使用设备的write特征值去向设备发送数据
  void writeData(String serviceUuid,String characteristicUuid,bool isNoResponse,Uint8List data){
    if(_state!=DeviceState.destroyed&&_state==DeviceState.connected) { //已连接才能去向设备写入数据
      FlutterBlueElves.instance._channel.invokeMethod('writeData',{"id":_id,"serviceUuid":serviceUuid,"characteristicUuid":characteristicUuid,"isNoResponse":isNoResponse,"data":data});//去向设备发送数据
    }
  }

  ///使用设备特征值的描述去向设备读取数据
  void readDescriptorData(String serviceUuid,String characteristicUuid,String descriptorUuid){
    if(_state!=DeviceState.destroyed&&_state==DeviceState.connected) { //已连接才能去向设备写入数据
      FlutterBlueElves.instance._channel.invokeMethod('readDescriptorData',{"id":_id,"serviceUuid":serviceUuid,"characteristicUuid":characteristicUuid,"descriptorUuid":descriptorUuid});//去向设备读取数据
    }
  }

  ///使用设备特征值描述去向设备发送数据
  void writeDescriptorData(String serviceUuid,String characteristicUuid,String descriptorUuid,Uint8List data){
    if(_state!=DeviceState.destroyed&&_state==DeviceState.connected) { //已连接才能去向设备写入数据
      FlutterBlueElves.instance._channel.invokeMethod('writeDescriptorData',{"id":_id,"serviceUuid":serviceUuid,"characteristicUuid":characteristicUuid,"descriptorUuid":descriptorUuid,"data":data});//去向设备发送数据
    }
  }

  ///获取设备返回数据的结果广播流
  Stream<DeviceSignalResult> get deviceSignalResultStream =>
      _deviceSignalResultStream;
}

class ScanResult {
  final String _id; //设备Id
  final String _name; //设备名称
  final String _localName;//设备localName
  final String _macAddress; //mac地址,ios没有返回
  final int _rssi; //蓝牙信号强度
  final List _uuids; //设备uuid
  final Map _manufacturerSpecificData;//厂商自定义数据
  final Uint8List _row;//原始广播包数据

  ScanResult._(this._id, this._name,this._localName, this._macAddress, this._rssi,
      this._uuids, this._manufacturerSpecificData,this._row);

  Uint8List get row => _row;


  String get localName => _localName;

  Map get manufacturerSpecificData => _manufacturerSpecificData;

  List get uuids => _uuids;

  int get rssi => _rssi;

  String get macAddress => _macAddress;

  String get name => _name;

  String get id => _id;

  /// 连接设备
  /// 返回设备对象
  Device connect({connectTimeout=0}){
    Device device=FlutterBlueElves.instance._deviceCache[_id];
    if(device==null) {//cache里面没有代表之前没有连接过,所以可以连接,除非将device.destroy(),android永远都是走这里
      device=Device._(_id);//创建设备对象
      FlutterBlueElves.instance._deviceCache[_id]=device;//将device加入到cache中
      device._state=DeviceState.connecting;//将对象状态置为连接中
      FlutterBlueElves.instance._channel.invokeMethod('connect',{"id":_id,"timeout":Platform.isAndroid?connectTimeout:connectTimeout~/1000});//去连接
    }else{//ios如果是同一个设备就会走这里
      device.connect(connectTimeout: connectTimeout);
    }
    return device;
  }
}

//返回发现的蓝牙服务
class BleService{
  final String _serviceUuid;//服务Uuid
  final List<BleCharacteristic> _characteristics;//特征值信息

  BleService(this._serviceUuid, this._characteristics);

  List<BleCharacteristic> get characteristics => _characteristics;

  String get serviceUuid => _serviceUuid; //特征值UUID

}

class BleCharacteristic{
  final String _uuid;
  final List<CharacteristicProperties> _properties;
  final List<BleDescriptor> _descriptors;

  BleCharacteristic(this._uuid, this._properties,this._descriptors);

  List<CharacteristicProperties> get properties => _properties;

  String get uuid => _uuid;

  List<BleDescriptor> get descriptors => _descriptors;
}

class BleDescriptor{
  final String _uuid;

  BleDescriptor(this._uuid);

  String get uuid => _uuid;
}

///设备返回数据的结果
class DeviceSignalResult{
  final DeviceSignalType _type;//信号类型
  final String _uuid;//UUID
  final bool _isSuccess;//是否成功
  final Uint8List _data;

  DeviceSignalResult(
      this._type, this._uuid, this._isSuccess, this._data);

  Uint8List get data => _data;

  bool get isSuccess => _isSuccess;

  String get uuid => _uuid;

  DeviceSignalType get type => _type; //写入返回的数据


}

enum AndroidBluetoothLack{
  locationPermission,locationFunction,bluetoothFunction
}

enum IosBluetoothState{
  unKnown,resetting,unSupport,unAuthorized,poweredOff,poweredOn
}

enum DeviceState { disconnected,disConnecting, connecting,connected, connectTimeout,initiativeDisConnected,destroyed }

enum CharacteristicProperties {
  broadcast,read, writeNoResponse,write, notify,indicate,signedWrite,extendedProps,notifyEncryptionRequired,indicateEncryptionRequired
}

enum DeviceSignalType{
  characteristicsRead,characteristicsWrite,characteristicsNotify,descriptorRead,descriptorWrite,unKnown
}