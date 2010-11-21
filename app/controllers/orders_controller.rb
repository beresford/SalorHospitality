class OrdersController < ApplicationController

  def index
    @tables = Table.all
    @last_finished_order = Order.find_all_by_finished(true).last
    @categories = Category.find(:all, :order => :sort_order)
  end

  def statusupdate_tables
    @tables = Table.all
    @last_finished_order = Order.find_all_by_finished(true).last
  end

  def show
    @client_data = File.exist?('client_data.yaml') ? YAML.load_file( 'client_data.yaml' ) : {}
    @order = Order.find(params[:id])
    @previous_order, @next_order = neighbour_orders(@order)
    respond_to do |wants|
      wants.html
      wants.bon { render :text => generate_escpos_invoice(@order) }
    end
  end

  def unsettled
    @unsettled_orders = Order.find(:all, :conditions => { :settlement_id => nil, :finished => true })
    unsettled_userIDs = Array.new
    @unsettled_orders.each do |uo|
      unsettled_userIDs << uo.user_id
    end
    unsettled_userIDs.uniq!
    @unsettled_users = User.find(:all, :conditions => { :id => unsettled_userIDs })
    flash[:notice] = t(:there_are_no_open_settlements) if @unsettled_users.empty?
  end

  def items
    respond_to do |wants|
      wants.bon { render :text => generate_escpos_items(:drink) }
    end
  end

  def split_invoice_all_at_once
    @order = Order.find(params[:id])
    @order.update_attributes(params[:order])
    @cost_centers = CostCenter.find_all_by_active(true)
    items_for_split_invoice = Item.find(:all, :conditions => { :order_id => @order.id, :partial_order => true })
    make_split_invoice(@order, items_for_split_invoice, :all)
    @orders = Order.find_all_by_finished(false, :conditions => { :table_id => @order.table_id })
    render 'split_invoice'
  end

  def split_invoice_one_at_a_time
    @item_to_split = Item.find(params[:id]) # find item on which was clicked
    @order = @item_to_split.order
    @cost_centers = CostCenter.find_all_by_active(true)
    make_split_invoice(@order, [@item_to_split], :one)
    @orders = Order.find_all_by_finished(false, :conditions => { :table_id => @order.table_id })
    render 'split_invoice'
  end

  def storno
    @order = Order.find(params[:id])
    @previous_order, @next_order = neighbour_orders(@order)
    @order.update_attributes(params[:order])
    items_for_storno = Item.find(:all, :conditions => { :order_id => @order.id, :storno_status => 1 })
    make_storno(@order, items_for_storno)
    @order = Order.find(params[:id]) # re-read
    respond_to do |wants|
      wants.html
      wants.js { render 'display_storno' }
    end
  end

  def separate_item
    @item=Item.find(params[:id])
    @separated_item = @item.clone
    @separated_item.count = 1
    @item.count -= 1
    @item.count == 0 ? @item.delete : @item.save
    @separated_item.save
    @order = @item.order
    @previous_order, @next_order = neighbour_orders(@order)
    respond_to do |wants|
      wants.js { render 'display_storno' }
    end
  end

  # This function not only prints, but also finishes orders
  def print
    @order = Order.find params[:id]
    @order.update_attributes params[:order]
    @order.update_attribute :finished, true
    @order.update_attribute :user, @current_user
    @order.order.order = nil if @order.order # unlink parent order from me
    if /tables/.match(request.referer)
      unfinished_orders_on_same_table = Order.find(:all, :conditions => { :table_id => @order.table, :finished => false })
      unfinished_orders_on_same_table.empty? ? redirect_to(orders_path) : redirect_to(table_path(@order.table))
    else
      redirect_to orders_path
    end
    File.open('order.escpos', 'w') { |f| f.write(generate_escpos_invoice(@order)) }
    `cat order.escpos > /dev/ttyPS#{ params[:port] }`
  end

  def display_order_form_ajax
    @table=Table.find(params[:id])
    @order=Order.find(:all, :conditions => { :table_id => @table.id, :finished => false }).last
  end

  def receive_order_attributes_ajax
    @tables = Table.all
    if not params[:order_action] == 'cancel_and_go_to_tables'
      @order = Order.find(params[:order][:id]) if not params[:order][:id].empty?
      if @order
        #similar to update
        @order.update_attributes(params[:order])
      else
        #similar to create
        @order = Order.new(params[:order])
        @order.user = @current_user
        @order.sum = calculate_order_sum @order
        @order.save
      end
      process_order(@order)
    end
    conditional_redirect_ajax(@order)
  end




  private

    def neighbour_orders(order)
      orders = Order.find_all_by_finished(true)
      idx = orders.index(order)
      previous_order = orders[idx-1]
      previous_order = order if previous_order.nil?
      next_order = orders[idx+1]
      next_order = order if next_order.nil?
      return previous_order, next_order
    end

    def process_order(order)
      order.items.each { |i| i.delete if i.count.zero? }
      order.delete and redirect_to orders_path and return if order.items.size.zero?
      order.update_attribute( :sum, calculate_order_sum(order) )

      File.open('bar.escpos', 'w') { |f| f.write(generate_escpos_items(:drink)) }
      `cat bar.escpos > /dev/ttyPS1` #1 = Bar

      File.open('kitchen.escpos', 'w') { |f| f.write(generate_escpos_items(:food)) }
      `cat kitchen.escpos > /dev/ttyPS0` #0 = Kitchen

      File.open('kitchen-takeaway.escpos', 'w') { |f| f.write(generate_escpos_items(:takeaway)) }
      `cat kitchen-takeaway.escpos > /dev/ttyPS0` #0 = Kitchen
    end

    def conditional_redirect(order)
      case params[:order_action]
        when 'save_and_go_to_tables'
          redirect_to orders_path
        when 'save_and_go_to_invoice'
          redirect_to table_path(order.table)
        when 'move_order_to_table'
          order = move_order_to_table(order, params[:target_table])
          redirect_to orders_path
      end
    end

    def conditional_redirect_ajax(order)
      case params[:order_action]
        when 'save_and_go_to_tables'
          render 'go_to_tables'
        when 'cancel_and_go_to_tables'
          render 'go_to_tables'
        when 'save_and_go_to_invoice'
          render 'go_to_invoice'
        when 'move_order_to_table'
          order = move_order_to_table(order, params[:target_table])
          render 'go_to_tables'
      end
    end

    def move_order_to_table(order,table_id)
      @target_order = Order.find(:all, :conditions => { :table_id => table_id, :finished => false }).first
      @target_order = Order.new(:table_id => table_id, :user_id => @current_user.id) if not @target_order
      order.items.each do |i|
        i.update_attribute :order, @target_order
      end
      @order.destroy
      return @target_order
    end

    def reduce_stocks(order)
      order.items.each do |item|
        item.article.ingredients.each do |ingredient|
          ingredient.stock.balance -= item.count * ingredient.amount
          ingredient.stock.save
        end
      end
    end


    def make_split_invoice(parent_order, split_items, mode)
      return if split_items.empty?
      if parent_order.order # if there already exists one child order, use it for the split invoice
        split_invoice = parent_order.order
      else # create a brand new split invoice, and make it belong to the parent order
        split_invoice = parent_order.clone
        split_invoice.save
        parent_order.order = split_invoice  # make an association between parent and child
        split_invoice.order = parent_order  # ... and vice versa
      end
      case mode
        when :all
          split_items.each do |i|
            i.update_attribute :order_id, split_invoice.id # move item to the new order
            i.update_attribute :partial_order, false # after the item has moved to the new order, leave it alone
          end
        when :one
          parent_item = split_items.first # in this mode there will only single items to split
          if parent_item.item
            split_item = parent_item.item
          else
            split_item = parent_item.clone
            split_item.count = 0
            split_item.save
            parent_item.item = split_item # make an association between parent and child
            split_item.item = parent_item # ... and vice versa
          end
          split_item.order = split_invoice # this is the actual moving to the new order
          split_item.count += 1
          parent_item.count -= 1
          parent_item.count == 0 ? parent_item.delete : parent_item.save
          split_item.save
      end
      parent_order = Order.find(parent_order.id) # re-read
      parent_order.delete if parent_order.items.empty?
      parent_order.update_attribute( :sum, calculate_order_sum(parent_order) ) if not parent_order.items.empty?
      split_invoice.update_attribute( :sum, calculate_order_sum(split_invoice) )
    end
    
    # storno_status: 1 = marked for storno, 2 = is storno clone, 3 = storno original
    #
    def make_storno(order, items_for_storno)
      return if items_for_storno.empty?
      items_for_storno.each do |item|
        next if item.storno_status == 3 # only one storno allowed per item
        storno_item = item.clone
        storno_item.save
        storno_item.update_attribute :storno_status, 2 # tis is a storno clone
        item.update_attribute :storno_status, 3 # this is a storno original
      end
    end
    
    
    def calculate_order_sum(order)
      subtotal = 0
      order.items.each do |item|
        p = item.real_price
        sum = item.count * p
        subtotal += item.count * p
      end
      return subtotal
    end


    def generate_escpos_invoice(order)
      client_data = File.exist?('client_data.yaml') ? YAML.load_file( 'client_data.yaml' ) : {}

      header =
      "\e@"     +  # Initialize Printer
      "\ea\x01" +  # align center

      "\e!\x38" +  # doube tall, double wide, bold
      client_data[:name] + "\n" +

      "\e!\x01" +  # Font B
      "\n" + client_data[:subtitle] + "\n" +
      "\n" + client_data[:address] + "\n\n" +
      client_data[:taxnumber] + "\n\n" +

      "\ea\x00" +  # align left
      "\e!\x01" +  # Font B
      t('served_by_X_on_table_Y', :waiter => order.user.title, :table => order.table.name) + "\n" +
      t('invoice_numer_X_at_time', :number => order.id, :datetime => l(order.created_at, :format => :long)) + "\n\n" +

      "\e!\x00" +  # Font A
      "               Artikel    EP    Stk   GP\n"

      sum_taxes = Array.new(Tax.count, 0)
      subtotal = 0
      list_of_items = ''
      order.items.each do |item|
        p = item.real_price
        p = -p if item.storno_status == 2
        sum = item.count * p
        subtotal += sum
        tax_id = item.article.category.tax.id
        sum_taxes[tax_id-1] += sum
        label = item.quantity_id ? "#{ item.quantity.prefix } #{ item.quantity.article.name } #{ item.quantity.postfix } #{ item.comment }" : item.article.name
        #label = Iconv.conv('ISO-8859-15//TRANSLIT','UTF-8',label)
        list_of_items += "%c %20.20s %7.2f %3u %7.2f\n" % [tax_id+64,label,p,item.count,sum]
      end

      sum =
      "                               -----------\r\n" +
      "\e!\x18" + # double tall, bold
      "\ea\x02" +  # align right
      "SUMME:   EUR %.2f\n\n" % subtotal.to_s +
      "\ea\x01" +  # align center
      "\e!\x01" # Font A

      tax_header = "          netto     USt.  brutto\n"

      list_of_taxes = ''
      Tax.all.each do |tax|
        tax_id = tax.id - 1
        next if sum_taxes[tax_id] == 0
        fact = tax.percent/100.00
        net = sum_taxes[tax_id]/(1.00+fact)
        gro = sum_taxes[tax_id]
        vat = gro-net

        list_of_taxes += "%c: %2i%% %7.2f %7.2f %8.2f\n" % [tax.id+64,tax.percent,net,vat,gro]
      end

      footer = 
      "\ea\x01" +  # align center
      "\e!\x00" + # font A
      "\n" + client_data[:slogan1] + "\n" +
      "\e!\x08" + # emphasized
      "\n" + client_data[:slogan2] + "\n" +
      client_data[:internet] + "\n\n\n\n\n\n\n" + 
      "\x1DV\x00" # paper cut

      output = header + list_of_items + sum + tax_header + list_of_taxes + footer
      output = Iconv.conv('ISO-8859-15','UTF-8',output)
      output.gsub!(/\xE4/,"\x84") #ä
      output.gsub!(/\xFC/,"\x81") #ü
      output.gsub!(/\xF6/,"\x94") #ö
      output.gsub!(/\xC4/,"\x8E") #Ä
      output.gsub!(/\xDC/,"\x9A") #Ü
      output.gsub!(/\xD6/,"\x99") #Ö
      output.gsub!(/\xDF/,"\xE1") #ß
      output.gsub!(/\xE9/,"\x82") #é
      output.gsub!(/\xE8/,"\x7A") #è
      output.gsub!(/\xFA/,"\xA3") #ú
      output.gsub!(/\xF9/,"\x97") #ù
      output.gsub!(/\xC9/,"\x90") #É
      return output
    end





    def generate_escpos_items(type)
      overall_output = ''

      Order.find_all_by_finished(false).each do |order|
        per_order_output = ''
        per_order_output +=
        "\e@"     +  # Initialize Printer
        "\e!\x38" +  # doube tall, double wide, bold

        "%-6.6s %13s\n" % [l(Time.now, :format => :time_short), order.table.name] +

        per_order_output += "=====================\n"

        printed_items_in_this_order = 0
        order.items.each do |i|
          next if (i.count <= i.printed_count)
          next if (type == :drink and i.category.food) or (type == :food and !i.category.food)

          usage = i.quantity ? i.quantity.usage : i.article.usage
          next if (type == :takeaway and usage != 'b') or (type != :takeaway and usage == 'b')

          printed_items_in_this_order =+ 1

          per_order_output += "%i %-18.18s\n" % [ i.count - i.printed_count, i.article.name]
          per_order_output += "  %-18.18s\n" % ["#{i.quantity.prefix} #{ i.quantity.postfix}"] if i.quantity
          per_order_output += "! %-18.18s\n" % [i.comment] if i.comment and not i.comment.empty?

          i.options.each { |o| per_order_output += "* %-18.18s\n" % [o.name] }

          #per_order_output += "---------------------\n"

          i.update_attribute :printed_count, i.count
        end

        per_order_output +=
        "\n\n\n\n" +
        "\x1DV\x00" # paper cut at the end of each order/table
        overall_output += per_order_output if printed_items_in_this_order != 0
      end

      overall_output = Iconv.conv('ISO-8859-15','UTF-8',overall_output)
      overall_output.gsub!(/\xE4/,"\x84") #ä
      overall_output.gsub!(/\xFC/,"\x81") #ü
      overall_output.gsub!(/\xF6/,"\x94") #ö
      overall_output.gsub!(/\xC4/,"\x8E") #Ä
      overall_output.gsub!(/\xDC/,"\x9A") #Ü
      overall_output.gsub!(/\xD6/,"\x99") #Ö
      overall_output.gsub!(/\xDF/,"\xE1") #ß
      overall_output.gsub!(/\xE9/,"\x82") #é
      overall_output.gsub!(/\xE8/,"\x7A") #è
      overall_output.gsub!(/\xFA/,"\xA3") #ú
      overall_output.gsub!(/\xF9/,"\x97") #ù
      overall_output.gsub!(/\xC9/,"\x90") #É
      return overall_output
    end



    def generate_escpos_test
      out = "\e@" # Initialize Printer
      0.upto(255) { |i|
        out += i.to_s + i.chr
      }
      return out
    end
end
