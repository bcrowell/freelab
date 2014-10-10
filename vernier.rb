require 'usb'

include ObjectSpace

# (c) 2010 Benjamin Crowell, licensed under GPL v2 (http://www.gnu.org/licenses/old-licenses/gpl-2.0.html)
# or Simplified BSD License (http://www.opensource.org/licenses/bsd-license.php)

$debug = false


class Sensor
  attr_reader :exceptions
  def initialize(lab_pro)
    @lab_pro = lab_pro
    @exceptions = []
  end
  def has_errors
    @exceptions.each {|e| return true if e.severity=="error"}
    return false
  end
  def print_errors_to_stderr
    $stderr.print "Listing of errors:\n"
    @exceptions.each {|e| $stderr.print "#{e.severity}: #{e.message}\n"}
    $stderr.print "...done\n"
  end
  def describe_sensor_type(type)
    return {'photogate'=>'photogate','motion'=>'motion detector','force'=>'force probe'}[type]
  end
end

class DigitalSensor < Sensor
  def initialize(lab_pro,type,channel=nil)
    # type is 'phototage' or 'motion'
    # channel is 1 for dig1, 2 for dig2, nil to autosense
    super(lab_pro)
    unless {'photogate'=>true,'motion'=>true}[type] then @exceptions.push(VernierException.new('error',@lab_pro,'illegal_digital_sensor_type',self,"Illegal digital sensor type: #{type}")); return end
    @lab_pro.write("1,1,14") # always have to set up an analog channel, even if not using it; cmd 1, p. 31; 14=voltage
    sensors = lab_pro.detect_digital_sensors
    if (channel==nil) then
      n_found = 0
      channel = nil
      (1..2).each {|x|
        s = sensors[x-1] # e.g., ['motion',{}]
        if s!=nil && s[0]==type then channel=x; n_found = n_found+1 end
      }
      describe = self.describe_sensor_type(type)
      if n_found>1 then @exceptions.push(VernierException.new('warn',@lab_pro,'multiple_sensors_found',self,"Both DIG/SONIC 1 and DIG/SONIC 2 have #{describe}s. We will only read out the one in channel #{channel}.")) end
      if n_found==0 then @exceptions.push(VernierException.new('error',@lab_pro,'sensor_not_found',self,"No #{describe} was detected in either DIG/SONIC 1 or DIG/SONIC 2.")) end
      if n_found==1 then @exceptions.push(VernierException.new('info',@lab_pro,'unique_sensor_found',self,"Data will be taken from the #{describe} plugged into DIG/SONIC #{channel}.")) end
    else
      if sensors[channel-1]==nil || sensors[channel-1][0]!=type then  @exceptions.push(VernierException.new('error',@lab_pro,'no_sensor',self,"No #{describe} was detected in DIG/SONIC #{channel}.")) end
    end
    @channel = channel
  end
end

class AnalogSensor < Sensor
  attr_reader :options # is a hash such as {'range'=>10}, which tells us the force probe is set to the 10 N scale
  def initialize(lab_pro,type,channel=nil)
    # type can only be 'force'
    # channel is 1-4, or nil to autosense
    @type = type
    super(lab_pro)
    unless {'force'=>true}[type] then @exceptions.push(VernierException.new('error',@lab_pro,'illegal_analog_sensor_type',self,"Illegal analog sensor type: #{type}")); return end
    sensors = lab_pro.detect_analog_sensors
    if (channel==nil) then
      n_found = 0
      channel = nil
      (1..4).each {|x|
        s = sensors[x-1] # e.g., ['force',{'range'=>10}]
        if s!=nil && s[0]==type then channel=x; n_found = n_found+1 end
      }
      describe = self.describe_sensor_type(type)
      if n_found>1 then @exceptions.push(VernierException.new('warn',@lab_pro,'multiple_sensors_found',self,"Multiple #{describe}s. We will only read out the one in channel #{channel}.")) end
      if n_found==0 then @exceptions.push(VernierException.new('error',@lab_pro,'sensor_not_found',self,"No #{describe} was detected in channels 1 through 4.")) end
      if n_found==1 then @exceptions.push(VernierException.new('info',@lab_pro,'unique_sensor_found',self,"Data will be taken from the #{describe} plugged into channel #{channel}.")) end
    else
      if sensors[channel-1]==nil || sensors[channel-1][0]!=type then @exceptions.push(VernierException.new('error',@lab_pro,'no_sensor',self,"No #{describe} was detected in channel #{channel}.")) end
    end
    @channel = channel
    return if self.has_errors
    @options=sensors[channel-1][1]
    @lab_pro.write("1,#{@channel},14") # 1=channel setup, p. 31; 14=read voltage 0-5 V
    # Docs say to do the following, but LoggerPro never actually uses command 3. Apparently this would only be needed in order to make it return data automatically
    # at a fixed time interval. See http://www.vernier.com/discussion/index.php?PHPSESSID=a6198q6ssjoik8eq73h3vl1ga2&topic=481.msg1350#msg1350
    if false then
      @lab_pro.write("3,0.5,-1,0") # data collection setup, p. 35; 0.5=samptime; -1=num points=real-time; 0=trigger type=immediate
      @lab_pro.read # Command 3 doesn't return anything itself, but the setup command above would cause the labpro to send back data every 0.5 seconds.
    end
    # Could do command 4 here for calibration.
  end

  def get_data
    result = @lab_pro.ask("9,#{@channel}")[0] # request channel data, p. 48; the bare {9,0} without the third mode operand is what LoggerPro emits
    # result is 0 to 5, in volts
    range = self.options["range"] # 10 or 50 N
    return -(result/2.5-1.0)*range # push is -, pull is +, following LoggerPro's sign convention
  end
end

class Photogate < DigitalSensor
  # photogate examples, pp. 14, 53
  # They define a bunch of modes, which IMO aren't particularly useful. There's nothing you can do with the modes that you can't do simply by
  # reading back the data and doing arithmetic on it. I've provided a convenience function for doing that in the case when you want pendulum timing.

  def initialize(lab_pro,channel=nil)
    # channel is 1 for dig1, 2 for dig2, nil to autosense
    super(lab_pro,'photogate',channel)
    self.set_up
  end

  def set_up
    return if self.has_errors
    self.clear_data
    @active = true
  end

  def clear_data
    return if self.has_errors
    @n_eaten = 0

    # 12=digital data capture, p. 51
    @lab_pro.write("12,#{40+@channel},2,1")
      # 12=digital data capture
      # 41,42=dig/sonic 1,2
      # 2=mode, measure pulse width
      # 1=measure time for which it's blocked

    @lab_pro.write("3,9999,1000,0")
      # triggering, etc.;  cmd 3, p. 35
      # 9999=samptime; p. 14 seems to say that this should just be set to some big number...??; they use 10 in examples; do I ever need to tell it to stop?
      # 1000=npoints
    # See comment above in force probe code re command 3 causing data to come back.
  end

  def n
    return if self.has_errors
    # number of available data points
    return @lab_pro.ask("12,#{40+@channel},0")[0].to_i
  end

  def t
    # returns an array containing the clock-times at which the leading edges occurred (photogate became blocked)
    return self.get_times('t')
  end

  def dt
    # returns an array containing lengths of the times for which the photogate was blocked
    return self.get_times('dt')
  end

  def get_times(mode,eat_em_up=true)
    return if self.has_errors
    raw_mode = {'t'=>-2,'dt'=>-1}[mode]
    # From the docs, the two lines below look like they should both do exactly the same thing. In fact, only the one that's not commented out that works.
    #result = @lab_pro.ask("12,#{40+@channel},#{raw_mode},#{@n_eaten}")
    result = @lab_pro.ask("12,#{40+@channel},#{raw_mode},0")[@n_eaten..-1]
      # final param=P1=first data point
    if eat_em_up then self.mark_read(result.length) end
    return result
  end

  def mark_read(m)
    @n_eaten += m
  end

  def pendulum
    return if self.has_errors
    tt = self.get_times('t',false)
    result = []
    tt.each_index { |i|
      if i%2==0 && i>=2 && i>=@n_eaten then
        result.push(tt[i]-tt[i-2]) 
      end
    }
    self.mark_read(2*result.length)
    return result
  end

  def activate
    return if self.has_errors
    if !@active then
      sleep 0.3 # in case data are still being read out from before it was inactivated and then reactivated
      self.clear_data
      @active = true
    end
  end

  def inactivate
    @active = false
  end
end

class LabPro
  def initialize(options={})
    # on return, check .warnings array
    #----- Decode args:
    n = 0
    if options["nth_labpro"]!=nil then n=options["nth_labpro"] end
    reset_on_open = true
    if options["reset_io_open"]!=nil then reset_on_open=options["reset_on_open"] end
    #----- Initialize state:
    @warnings = []
    @is_open = false
    @interface_claimed = false
    @timeout = 5000 # milliseconds
    @when_i_die = {'interface_claimed'=>@interface_claimed}
    #----- Find the LabPro:
    dev = nil # will be a USB::Device
    count = 0
    USB.devices.each { |x|
      if x.idProduct==1 && x.idVendor==0x08f7 && count==n then dev=x; break end
      # 8f7 is vernier; product id's for vernier are 1=default, 2=GoTemp, 3=GoLink, 4=GoMotion, 5=LabQuest, 6=CK Spectrometer, 7=Mini Gas Chromatograph, 8=standalone DAQ
      # LabPro has product id=1
      # vendor 2457 is Ocean Optics, business/technical ties with Vernier, wrote vstusb kernel module
    }
    if dev==nil then raise VernierException.new('error',self),"LabPRO not found" end
    @dev = dev
    #----- Find input and output endpoints:
    @in_endpoint = nil
    @out_endpoint = nil
    dev.endpoints.each { |e|
      if (!e.revoked?) then
        addr = e.bEndpointAddress
        num = addr & 0b00001111
        if (addr & 0b10000000) == 0 then
          @out_endpoint = num
        else
          @in_endpoint = num
        end
      end
    }
    if @in_endpoint==nil  then raise VernierException.new('error',self),"No input endpoint found", caller end
    if @out_endpoint==nil then raise VernierException.new('error',self),"No output endpoint found" end
    #----- Open the device:
    @h = @dev.open # h is a USB::DevHandle
    @when_i_die["h"] = @h
    @is_open = true
    @when_i_die["is_open"] = @is_open
    ObjectSpace.undefine_finalizer(self); ObjectSpace.define_finalizer( self, proc {|id| LabPro.finalize(id,@when_i_die) })
    #----- If necessary, detach vstusb driver. This is needed on kernels 2.6.31-14 through about 2.6.32, in which the kernel would automatically
    #      claim the interface using this driver.
    @interface = 0 # I just guessed the 0, but it does seem to be right. Changing it to 1 gives Errno::ENOENT elsewhere.
    if File.exist?("/dev/vstusb0") then 
      # ...on Windows, the file won't exist, so this is harmless
      @h.usb_detach_kernel_driver_np(@interface,@interface) # I think the need to supply @interface twice is a bug in ruby-usb.
    end
    #----- Claim the interface:
    @when_i_die["interface"] = @interface
    @h.claim_interface(@interface) # libusb docs say this is required before doing bulk_write; if this fails due to permissions, see README for workarounds
    @interface_claimed = true
    @when_i_die["interface_claimed"] = @interface_claimed
    ObjectSpace.undefine_finalizer(self); ObjectSpace.define_finalizer( self, proc {|id| LabPro.finalize(id,@when_i_die) })
    #----- Do a reset, if requested:
    self.reset if reset_on_open
    #----- Check status:
    n_tries = 0
    while n_tries<3
      n_tries += 1
      status = self.ask("7") # 7=get status
      break if status.length==17
      $stderr.print "status has wrong length: #{status.join(",")}\n"
      $stderr.print "reading, resetting and trying again\n"
      $stderr.print "read left-over data: #{self.read_ignoring_timeout.join(",")}\n" # Try to slurp up any left-over data that's messing us up. If there is none, then catch the resulting time-out.
      self.write("0")
      sleep 0.01
    end
    if n_tries>1 then $stderr.print "got reasonable status after #{n_tries} tries\n" end
    (@firmware_version,@error_status,@battery_warning) = status
    if @error_status!=0 then print "error status=#{@error_status}\n"; raise VernierException.new('error',self),"Nonzero error status of LabPro is #{@error_status}" end
    if @battery_warning!=0.0 then @warnings.push "low battery" end
  end
  def ask(s)
    self.write(s)
    return self.read()
  end
  def write(s)
    if !@is_open then raise VernierException.new('error',self),"Can't write, not open" end
    data = "s{#{s}}\r"
    print "writing s{#{s}}CR, #{data.length} bytes \n" if $debug
    result = @h.usb_bulk_write(@out_endpoint,data,@timeout)
    # return value is # of bytes written, or negative value if error
    raise VernierException.new('error',self),"Negative return value #{result} on usb_bulk_write" if result<0
    raise VernierException.new('error',self),"Tried to write #{data.length} bytes, only wrote #{result}, on usb_bulk_write" if result<data.length
  end
  def read()
    # returns an array
    if !@is_open then raise VernierException.new('error',self),"Can't read, not open" end
    data = ''
    while true
      buffer = ' ' * 64
      result = @h.usb_bulk_read(@in_endpoint,buffer,@timeout)
      if result<0 then return nil end
      data = data + buffer
      if buffer =~ /\}/ then break end
    end
    print "read #{data}, #{data.length} bytes\n" if $debug
    inside = ''
    if !(data=~/\{(.*)\}/) then return [data] end # don't know if this ever actually happens, but maybe on commands like 116?
    inside = $1
    # strip leading and trailing whitespace
    inside.gsub!(/\s+$/) {''}
    inside.gsub!(/^\s+/) {''}
    # numbers are always in this format: +6.06270E+00
    # If a result is in this format, convert it from string to floating point.
    return inside.split(/\s*,\s*/).collect{|x| x=~/^\s*[+\-]\d\.\d+E[+\-]\d+\s*$/ ? x.to_f : x}
  end
  def read_ignoring_timeout
    begin
      return self.read
      rescue SystemCallError # Errno::ETIMEDOUT
    end
    return nil
  end
  def detect_digital_sensors
    # Returns an array with two elements, saying what type of sensor is plugged into each digital input; nil if no sensor in that input.
    # Sensor types currently supported are 'photogate' and 'motion'. (I don't think Vernier sells any other digital sensors.)
    # An 'unknown' type means something *is* plugged in, but we don't know what it is.
    return detect_sensors(0,1,4,true)
  end
  def detect_analog_sensors
    # Similar to detect_digital_sensors. Returns an array with four elements.
    return detect_sensors(0,3,0,false)
  end
  def detect_sensors(ch1,ch2,add,digital)
    # This is a private method. Public methods are detect_digital_sensors and detect_analog_sensors.
    # for digital sensors: ch1=0,ch2=1,add=4
    # for analog sensors:  ch1=0,ch2=3,add=0
    nch = ch2-ch1+1
    result = [nil] * nch
    # In the following, command 80 and return codes 4.0 and 26.0 are not documented, were found by reverse-engineering. They were later
    # confirmed by Dave Vernier: http://www.vernier.com/discussion/index.php?PHPSESSID=a6198q6ssjoik8eq73h3vl1ga2&topic=481.msg1350#msg1350
    info = self.ask("80,0")
    (ch1..ch2).each { |i|
      code = info[i+add]
      if !close_to(code,0.0) then
        this_is = 'unknown'
        if digital then
          if close_to(code,2.0) then this_is=['motion',{}] end
          if close_to(code,4.0) then this_is=['photogate',{}] end
        else
          if close_to(code,25.0) then this_is=['force',{'range'=>10}] end # dual-range force sensor on 10 N scale
          if close_to(code,26.0) then this_is=['force',{'range'=>50}] end # dual-range force sensor on 50 N scale
        end
        result[i] = this_is
      end
    }
    return result
  end
  private :detect_sensors
  def reset # reset the LabPro (clear RAM)
    if @is_open then self.write("0") else raise VernierException.new('error',self),"Can't reset, not open" end
  end
  def status
    if !@is_open then raise VernierException.new('error',self),"Can't get status, not open" end
    
  end
  def close
     # It's not necessary to do an explicit close, since the finalizer automatically gets called when the object goes out of scope. May want to do an explicit
     # reset, however.
     LabPro.finalize(self.object_id,@when_i_die)
     @interface_claimed = false
     @is_open = false
     @when_i_die = []
     @h = nil
  end
  def LabPro.finalize(id,data)
    h=data["h"]
    return if h==nil
    if data["interface_claimed"] then h.release_interface(data["interface"]) end
    if data["is_open"] then h.usb_close() end
  end
  def close_to(x,y)
    return (x-y).abs<0.01
  end
end

class VernierException < IOError
  attr_reader :severity,:lab_pro,:code,:sensor,:message
  def initialize(severity,lab_pro,code='',sensor=nil,message='')
    @severity = severity # can be 'error','warn', or 'info'
    @lab_pro = lab_pro
    @code = code
    @sensor = sensor
    @message = message
  end
end
