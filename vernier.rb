require 'usb'
include ObjectSpace

# (c) 2010 Benjamin Crowell, licensed under GPL v2 (http://www.gnu.org/licenses/old-licenses/gpl-2.0.html)
# or Simplified BSD License (http://www.opensource.org/licenses/bsd-license.php)

# Sample use:
#    ruby1.8 -e 'require "vernier.rb"; l=LabPro.new; p=Photogate.new(l,1); sleep 10; print p.dt().join(" "); l.reset'
#    The ruby1.8 is because on my home system, usb.rb isn't installed correctly to work with ruby 1.9.
# to do:
#   Make the channel argument to the Photogate constructor optional, and make the software autodetect which channel the sensor is in. But how
#        to do this? http://www.vernier.com/discussion/index.php/topic,477.0.html
#   Figure out how to make it automatically kill off vstusb: http://www.vernier.com/discussion/index.php/topic,476.0.html
#   Add more types of sensors.

$debug = false


class Sensor
  def initialize(lab_pro)
    @lab_pro = lab_pro
  end
end

class DigitalSensor < Sensor
  def initialize(lab_pro)
    super(lab_pro)
    @lab_pro.write("1,1,14") # always have to set up an analog channel, even if not using it; cmd 1, p. 31; 14=voltage
  end
end

class Photogate < DigitalSensor
  # photogate examples, pp. 14, 53
  # They define a bunch of modes, which IMO aren't particularly useful. There's nothing you can do with the modes that you can't do simply by
  # reading back the data and doing arithmetic on it. I've provided a convenience function for doing that in the case when you want pendulum timing.
  def initialize(lab_pro,channel)
    # channel is 1 for dig1, 2 for dig2
    super(lab_pro)
    @channel = channel
    self.set_up
  end

  def set_up
    self.clear_data
    @active = true
  end

  def clear_data
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
  end

  def n
    # number of available data points
    return @lab_pro.ask("12,#{40+@channel},0")[0].to_i
  end

  def t
    # returns an array containing the clock-times at which the leading edges occurred (photogate became blocked)
    return self.get_times(-2)
  end

  def dt
    # returns an array containing lengths of the times for which the photogate was blocked
    return self.get_times(-1)
  end

  def get_times(mode)
    # From the docs, the two lines below look like they should both do exactly the same thing. In fact, only the one that's not commented out works.
    #return @lab_pro.ask("12,#{40+@channel},#{mode},#{@n_eaten}")
    return @lab_pro.ask("12,#{40+@channel},#{mode},0")[@n_eaten..-1]
      # -1=mode=read out pulse widths
      # final param=P1=first data point
  end

  def mark_read(m)
    @n_eaten += m
  end

  def pendulum
    tt = self.t
    if @pendulum_stored_time!=nil then tt.unshift(@pendulum_stored_time); @pendulum_stored_time=nil end
    result = []
    tt.each_index {|i| result.push(tt[i]-tt[i-2]) if i%2==0 && i>=2 }
    if tt.length%2==1 then @pendulum_stored_time=tt.pop else self.clear_data end
    return result
  end

  def activate
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
    if File.exist?("/dev/vstusb0") then raise IOError,"Device /dev/vstusb0 exists, so vstusb driver has claimed the LabPro. To prevent this, add 'blacklist vstusb' to /etc/modprobe.d/blacklist.conf .",caller end
    # ...on Windows, the file won't exist, so this is harmless
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
      # 8f7 is vernier; labquest is product id 5
    }
    if dev==nil then raise IOError,"LabPRO not found",caller end
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
    if @in_endpoint==nil  then raise IOError,"No input endpoint found", caller end
    if @out_endpoint==nil then raise IOError,"No output endpoint found",caller end
    #----- Open the device:
    @h = @dev.open # h is a USB::DevHandle
    @when_i_die["h"] = @h
    @is_open = true
    @when_i_die["is_open"] = @is_open
    ObjectSpace.undefine_finalizer(self); ObjectSpace.define_finalizer( self, proc {|id| LabPro.finalize(id,@when_i_die) })
    #----- Claim the interface:
    @interface = 0 # I just guessed the 0, but it does seem to be right. Changing it to 1 gives Errno::ENOENT elsewhere.
    @when_i_die["interface"] = @interface
    @h.claim_interface(@interface) # libusb docs say this is required before doing bulk_write
    @interface_claimed = true
    @when_i_die["interface_claimed"] = @interface_claimed
     ObjectSpace.undefine_finalizer(self); ObjectSpace.define_finalizer( self, proc {|id| LabPro.finalize(id,@when_i_die) })
    #----- Do a reset, if requested:
    self.reset if reset_on_open
    #----- Check status:
    status = self.ask("7") # 7=get status
    (@firmware_version,@error_status,@battery_warning) = status
    if @error_status!=0 then raise IOError,"Nonzero error status of LabPro is #{@error_status}",caller end
      #...sometimes comes back with timing data in status!? can tell it's not really an error code because it's not an integer
    if @battery_warning!=0.0 then @warnings.push "low battery" end
  end
  def ask(s)
    self.write(s)
    return self.read()
  end
  def write(s)
    if !@is_open then raise IOError,"Can't write, not open",caller end
    data = "s{#{s}}\r"
    print "writing s{#{s}}CR, #{data.length} bytes \n" if $debug
    result = @h.usb_bulk_write(@out_endpoint,data,@timeout)
    # return value is # of bytes written, or negative value if error
    raise IOError,"Negative return value #{result} on usb_bulk_write",caller if result<0
    raise IOError,"Tried to write #{data.length} bytes, only wrote #{result}, on usb_bulk_write",caller if result<data.length
  end
  def read()
    # returns an array
    if !@is_open then raise IOError,"Can't read, not open",caller end
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
  def detect_digital_sensors
    # Returns an array with two elements, saying what type of sensor is plugged into each digital input; nil if no sensor in that input.
    # The only type of sensor for which this has actually been tested is a photogate.
    # Sensor types are 'photogate','motion_feet','motion_meters','unknown'. The 'unknown' type means something *is* plugged in, but we don't know what it is.
    result = []
    (1..2).each { |ch|
      self.write("9,#{10+ch},0") # p. 48
      channel_data = self.read[0]
      if close_to(channel_data,-999.9) then
        # Could either be a photogate or nothing plugged in at all.
        self.write("8,#{10+ch},0") # not really documented (see pp. 47, 31), but seems to work
        this_is = (close_to(self.read[0],4.0) ? 'photogate' : nil)
      else
        # Haven't tested this, but from pp. 48 and 77 of the docs it looks like channel_data is now the resistance of the IDENT resistor, probably in units of kOhms.
        this_is = 'unknown'
        {15.0 => 'motion_meters',22.0 => 'motion_meters',10.0=>'motion_feet'}.each {|resistance,sensor| # p. 77
          this_is = sensor if close_to(channel_data,resistance)
        }
      end
      result.push(this_is)
    }
    return result
  end
  def reset # reset the LabPro (clear RAM)
    if @is_open then self.write("0") else raise IOError,"Can't reset, not open",caller end
  end
  def status
    if !@is_open then raise IOError,"Can't get status, not open",caller end
    
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
